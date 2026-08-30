{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Bootstrap helpers: create/update a superadmin user without any UI
-- (first-run chicken-and-egg, design_docs/13 §"Bootstrap & lockout
-- protection"). Used by the @create-user@ CLI and by the
-- @INITIAL_ADMIN_EMAIL@/@INITIAL_ADMIN_PASSWORD@ env seed (same pattern
-- as 05-web-and-live-view.md, mirrored from the leader's seedAdminUser
-- but ALSO assigning the superadmin role).
module AdminWeb.Bootstrap
  ( bootstrapUser,
    bootstrapFromEnv,
    enableGuest,
  )
where

import Control.Exception (bracket)
import Control.Monad (forM_, void)
import qualified Data.ByteString.Char8 as BSC
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Database.PostgreSQL.Simple as PG
import Hnvr.Core.Authz (guestRoleId, superadminRoleId)
import Hnvr.Core.Logging (logInfo)
import IHP.AuthSupport.Authentication (hashPassword)
import IHP.Prelude
import qualified System.Environment as Env

-- | Idempotent: creates the user (or rotates the password), assigns the
-- seeded superadmin role, and writes an admin_audit row.
bootstrapUser :: Text -> Text -> IO ()
bootstrapUser email password = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  hash <- hashPassword password
  bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn -> do
    void
      $ PG.execute
        conn
        "INSERT INTO users (email, password_hash) VALUES (?, ?) \
        \ON CONFLICT (email) DO UPDATE SET password_hash = EXCLUDED.password_hash"
        (email, hash)
    void
      $ PG.execute
        conn
        "INSERT INTO user_roles (user_id, role_id) \
        \SELECT id, ? FROM users WHERE email = ? ON CONFLICT DO NOTHING"
        (superadminRoleId, email)
    void
      $ PG.execute
        conn
        "INSERT INTO admin_audit (actor_id, action, object_kind, object_id, payload) \
        \SELECT id, 'user.bootstrap', 'user', id::text, NULL FROM users WHERE email = ?"
        (PG.Only email)

-- | Env seed, mirroring the leader's INITIAL_ADMIN_* contract. No-ops
-- when either var is unset.
bootstrapFromEnv :: IO ()
bootstrapFromEnv = do
  mEmail <- Env.lookupEnv "INITIAL_ADMIN_EMAIL"
  mPassword <- Env.lookupEnv "INITIAL_ADMIN_PASSWORD"
  forM_ ((,) <$> mEmail <*> mPassword) $ \(email, password) -> do
    bootstrapUser (T.pack email) (T.pack password)
    logInfo ("hnvr-admin: ensured admin user " <> T.pack email)

-- | Re-create the seeded guest role (anonymous requests) with its
-- default grants (dashboard + live pages, wildcard view_live) after a
-- deliberate delete. Idempotent — existing grants are left alone.
-- The guest role is an ordinary role since migration 0019; deleting it
-- in the UI is the supported way to restore the full login wall.
enableGuest :: IO ()
enableGuest = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn ->
    PG.withTransaction conn $ do
      void
        $ PG.execute
          conn
          "INSERT INTO roles (id, name, description, is_system) \
          \VALUES (?, 'guest', 'Anonymous (unauthenticated) requests', FALSE) \
          \ON CONFLICT (name) DO NOTHING"
          (PG.Only guestRoleId)
      forM_ (["dashboard", "live"] :: [Text]) $ \p ->
        void
          $ PG.execute
            conn
            "INSERT INTO role_page_perms (role_id, page) VALUES (?, ?::page_kind) ON CONFLICT DO NOTHING"
            (guestRoleId, p)
      void
        $ PG.execute
          conn
          "INSERT INTO role_camera_perms (role_id, camera_id, action) \
          \SELECT ?, NULL, 'view_live' WHERE NOT EXISTS ( \
          \  SELECT 1 FROM role_camera_perms WHERE role_id = ? AND camera_id IS NULL AND action = 'view_live')"
          (guestRoleId, guestRoleId)
      void (PG.execute_ conn "NOTIFY roles_events, 'guest re-enabled'")
      logInfo "hnvr-admin: guest role present with default grants"

defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"
