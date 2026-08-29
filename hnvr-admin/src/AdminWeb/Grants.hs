{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Grant-table access for hnvr-admin. The mapping tables
-- (user_roles, role_page_perms, role_camera_perms) have composite PKs
-- and no IHP models (Schema.sql models only @roles@/@admin_audit@), so
-- everything here is raw postgresql-simple on one-shot connections —
-- admin mutations are rare and transactional.
--
-- Every mutation ends with @NOTIFY roles_events@ so the end-user app's
-- RoleSet cache ('Hnvr.Web.Authz.startAuthzCacheInvalidator') busts
-- immediately; the 30 s TTL is the backstop.
module AdminWeb.Grants
  ( RoleGrants (..),
    emptyRoleGrants,
    fetchRoleGrants,
    replaceRoleGrants,
    fetchUserRoleIds,
    replaceUserRoles,
    countSuperadminHolders,
    userHoldsSuperadmin,
    notifyRolesChanged,
  )
where

import Control.Exception (bracket)
import Control.Monad (forM_, void)
import qualified Data.ByteString.Char8 as BSC
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import Data.UUID (UUID)
import qualified Database.PostgreSQL.Simple as PG
import Database.PostgreSQL.Simple.Types (Only (..))
import Hnvr.Core.Authz
import IHP.Prelude
import qualified System.Environment as Env

-- | A role's full grant set: pages, wildcard camera actions, and
-- per-camera overrides (camera id → actions; overrides REPLACE the
-- wildcard for that camera — 'cameraAllowed').
data RoleGrants = RoleGrants
  { rgPages :: [PageKind],
    rgWildcard :: [CameraAction],
    rgOverrides :: [(UUID, [CameraAction])]
  }
  deriving stock (Eq, Show)

emptyRoleGrants :: RoleGrants
emptyRoleGrants = RoleGrants [] [] []

fetchRoleGrants :: UUID -> IO RoleGrants
fetchRoleGrants roleId = withDb $ \conn -> do
  pageRows <- PG.query conn "SELECT page::text FROM role_page_perms WHERE role_id = ?" (Only roleId)
  wildRows <- PG.query conn "SELECT action::text FROM role_camera_perms WHERE role_id = ? AND camera_id IS NULL" (Only roleId)
  ovrRows <- PG.query conn "SELECT camera_id, action::text FROM role_camera_perms WHERE role_id = ? AND camera_id IS NOT NULL" (Only roleId)
  let pages = mapMaybe (pageKindFromText . fromOnly) pageRows
      wild = mapMaybe (cameraActionFromText . fromOnly) wildRows
      overrides = foldr insertOvr [] [(cam, act) | (cam, Just act) <- [(c, cameraActionFromText a) | (c, a) <- ovrRows]]
  pure RoleGrants {rgPages = pages, rgWildcard = wild, rgOverrides = overrides}
  where
    insertOvr (cam, act) [] = [(cam, [act])]
    insertOvr (cam, act) ((c, acts) : rest)
      | c == cam = (c, act : acts) : rest
      | otherwise = (c, acts) : insertOvr (cam, act) rest

-- | Full replacement of a role's grants in one transaction (delete +
-- reinsert), then NOTIFY. Callers guard is_system roles separately
-- ('canDeleteRole' — system roles are never edited via the UI).
replaceRoleGrants :: UUID -> [PageKind] -> [CameraAction] -> [(UUID, [CameraAction])] -> IO ()
replaceRoleGrants roleId pages wildcard overrides = withDb $ \conn ->
  PG.withTransaction conn $ do
    void $ PG.execute conn "DELETE FROM role_page_perms WHERE role_id = ?" (Only roleId)
    void $ PG.execute conn "DELETE FROM role_camera_perms WHERE role_id = ?" (Only roleId)
    forM_ pages $ \p ->
      void
        $ PG.execute
          conn
          "INSERT INTO role_page_perms (role_id, page) VALUES (?, ?::page_kind)"
          (roleId, pageKindToText p)
    forM_ wildcard $ \a ->
      void
        $ PG.execute
          conn
          "INSERT INTO role_camera_perms (role_id, camera_id, action) VALUES (?, NULL, ?::camera_action)"
          (roleId, cameraActionToText a)
    forM_ overrides $ \(cam, actions) ->
      forM_ actions $ \a ->
        void
          $ PG.execute
            conn
            "INSERT INTO role_camera_perms (role_id, camera_id, action) VALUES (?, ?, ?::camera_action)"
            (roleId, cam, cameraActionToText a)
    notifyRolesChanged' conn

fetchUserRoleIds :: UUID -> IO [UUID]
fetchUserRoleIds userId = withDb $ \conn -> do
  rows <- PG.query conn "SELECT role_id FROM user_roles WHERE user_id = ?" (Only userId)
  pure (map fromOnly rows)

-- | Replace a user's role set. The last-superadmin guard
-- ('canRemoveSuperadminGrant') is the CALLER's job — this just writes.
replaceUserRoles :: UUID -> [UUID] -> IO ()
replaceUserRoles userId roleIds = withDb $ \conn ->
  PG.withTransaction conn $ do
    void $ PG.execute conn "DELETE FROM user_roles WHERE user_id = ?" (Only userId)
    forM_ roleIds $ \rid ->
      void
        $ PG.execute
          conn
          "INSERT INTO user_roles (user_id, role_id) VALUES (?, ?) ON CONFLICT DO NOTHING"
          (userId, rid)
    notifyRolesChanged' conn

countSuperadminHolders :: IO Int
countSuperadminHolders = withDb $ \conn -> do
  rows <- PG.query conn "SELECT COUNT(*)::int FROM user_roles WHERE role_id = ?" (Only superadminRoleId)
  pure (maybe 0 fromOnly (safeHead rows))

userHoldsSuperadmin :: UUID -> IO Bool
userHoldsSuperadmin userId = withDb $ \conn -> do
  rows <-
    PG.query
      conn
      "SELECT EXISTS (SELECT 1 FROM user_roles WHERE user_id = ? AND role_id = ?)"
      (userId, superadminRoleId)
  pure (maybe False fromOnly (safeHead rows))

-- | Bust every listener's RoleSet cache. Uses its own connection
-- (NOTIFY outside a transaction for one-off use from mutations that
-- don't touch grant tables, e.g. user delete).
notifyRolesChanged :: IO ()
notifyRolesChanged = withDb notifyRolesChanged'

notifyRolesChanged' :: PG.Connection -> IO ()
notifyRolesChanged' conn = void (PG.execute_ conn "NOTIFY roles_events")

withDb :: (PG.Connection -> IO a) -> IO a
withDb f = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  bracket (PG.connectPostgreSQL dbUrl) PG.close f

safeHead :: [a] -> Maybe a
safeHead [] = Nothing
safeHead (x : _) = Just x

defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"
