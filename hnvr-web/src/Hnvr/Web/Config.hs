{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | IHP FrameworkConfig for HNVR's leader node.
--
-- This is the bridge between IHP's runtime and our app. We use IHP for the
-- web/HTTP layer (controllers, sessions, schema designer hook points) but
-- we override the WAI middleware to serve @/healthz@ without touching the
-- database — important because Postgres is a SaaS dependency that may be
-- unreachable during early boot, but healthchecks must always succeed.
--
-- The leader also opens a NATS bus connection at startup via
-- 'addInitializer'. The connection persists for the lifetime of the
-- process (nats-queue runs an internal receiver thread). Phase 1 will
-- store the handle in an MVar so 'EventWriter' can publish on it.
module Hnvr.Web.Config
  ( config,
  )
where

import qualified Control.Exception as E
import Control.Monad (void)
import Data.Maybe (fromMaybe, maybe)
import qualified Data.Text as T
import Generated.Types
import Hnvr.Core.Logging (logError, logInfo)
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Node.HealthReporter (startHealthReporter)
import Hnvr.Web.AssignmentCoordinator (startAssignmentCoordinator)
import Hnvr.Web.Auth ()
import Hnvr.Web.ConfigBroadcaster (startConfigBroadcaster)
import Hnvr.Web.EventWriter (startEventWriter)
import Hnvr.Web.HealthCache (startHealthCache)
import Hnvr.Web.MediaMTXConfigSyncer (startMediaMTXConfigSyncer)
import Hnvr.Web.WhepProxy (whepMiddleware)
import IHP.AuthSupport.Authentication (hashPassword)
import IHP.FrameworkConfig
import IHP.FrameworkConfig.Types (AuthMiddleware (..), FrameworkConfig)
import IHP.LoginSupport.Middleware (authMiddleware)
import IHP.ModelSupport (ModelContext, sqlExec)
import IHP.Prelude
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai
import qualified Network.Wai.Middleware.HealthCheckEndpoint as HealthCheck
import qualified System.Environment as Env

-- | 'IHP.FrameworkConfig.ConfigBuilder' consumed by @IHP.Server.run@.
config :: ConfigBuilder
config = do
  -- Default APP_STATIC to the in-tree static/ dir when the env var is
  -- unset. IHP's @initStaticApp@ reads APP_STATIC *after* this builder
  -- runs, so setEnv here wins for cabal run, @./result/bin/hnvr-leader@
  -- from the repo root, and devenv. NixOS production sets APP_STATIC
  -- explicitly via @nix/module.nix@ (@''${dataDir}/static@) so this
  -- default is only used in dev.
  liftIO
    $ Env.lookupEnv "APP_STATIC"
    >>= \case
      Just _ -> pure ()
      Nothing -> Env.setEnv "APP_STATIC" "hnvr-web/static"

  option $ CustomMiddleware whepMiddleware
  option $ CustomMiddleware healthzMiddleware
  option $ AuthMiddleware (authMiddleware @User)
  addInitializer connectNatsAndStartEventWriter
  addInitializer seedAdminUser

-- | Idempotent INSERT of the bootstrap admin user from
-- @INITIAL_ADMIN_EMAIL@ + @INITIAL_ADMIN_PASSWORD@ env. Runs at leader boot.
-- Silently no-ops if either env var is unset (dev mode). 'ON CONFLICT' makes
-- it safe to leave the env vars set across restarts.
seedAdminUser :: (?modelContext :: ModelContext) => IO ()
seedAdminUser = do
  mEmail <- Env.lookupEnv "INITIAL_ADMIN_EMAIL"
  mPassword <- Env.lookupEnv "INITIAL_ADMIN_PASSWORD"
  case (mEmail, mPassword) of
    (Just email, Just password) -> do
      -- Coerce String → Text before INSERT: hasql serialises String
      -- (a.k.a. [Char]) as a PG array, which would store the email as
      -- `{a,d,m,i,n,@,...}` and break filterWhereCaseInsensitive lookups
      -- in IHP's createSessionAction. See pitfall #57.
      let emailT = cs email :: Text
      hash <- hashPassword (cs password)
      void
        $ sqlExec
          -- DO UPDATE (not DO NOTHING) so changing INITIAL_ADMIN_PASSWORD
          -- in the env takes effect on the next leader boot. Without
          -- this, the very first seed wins forever and you can't log
          -- in after rotating the password.
          "INSERT INTO users (email, password_hash, is_admin) \
          \ VALUES (?, ?, TRUE) \
          \ ON CONFLICT (email) DO UPDATE \
          \    SET password_hash = EXCLUDED.password_hash, \
          \        is_admin = TRUE"
          (emailT, hash)
      logInfo ("leader: ensured admin user " <> emailT)
    _ -> logInfo "leader: INITIAL_ADMIN_EMAIL/PASSWORD unset; skipping admin seed"

-- | Connect to the NATS bus using @HNVR_NATS_URI@ (default localhost),
-- then spawn the EventWriter drain loop on the same bus. Best-effort: if
-- NATS is unreachable (race with systemd ordering, network not yet up,
-- broker down), we log and continue. Phase 0 needs /healthz to succeed
-- even when NATS is flapping. systemd's @Restart=on-failure@ will still
-- catch real crashes.
--
-- MediaMTXConfigSyncer is independent of NATS and runs regardless.
connectNatsAndStartEventWriter :: (?context :: FrameworkConfig, ?modelContext :: ModelContext) => IO ()
connectNatsAndStartEventWriter = do
  startMediaMTXConfigSyncer
    `E.catch` \(e :: E.SomeException) ->
      logError ("leader: MediaMTXConfigSyncer start failed: " <> cs (show e))
  let defaultUri = "nats://nats:nats@localhost:4222"
  uri <- fromMaybe defaultUri <$> Env.lookupEnv "HNVR_NATS_URI"
  let connect' = do
        bus <- Bus.connect Bus.defaultConfig {Bus.busUri = uri}
        logInfo ("leader: connected to NATS: " <> cs (uri :: String))
        startEventWriter bus ?modelContext
        _ <- startHealthCache bus
        startAssignmentCoordinator bus
        startConfigBroadcaster bus
        host <- maybe "hnvr-2" T.pack <$> Env.lookupEnv "HNVR_HOST"
        startHealthReporter bus host
  connect' `E.catch` \(e :: E.SomeException) ->
    logError ("leader: NATS connect failed (continuing without bus): " <> cs (show e))

-- | WAI middleware that short-circuits @/healthz@ and @/_healthz@ with 200 OK.
-- Falls through to the inner IHP app for everything else.
healthzMiddleware :: Wai.Middleware
healthzMiddleware app request respond
  | path == "/healthz" = respond okResponse
  | otherwise = HealthCheck.healthCheck app request respond
  where
    path = Wai.rawPathInfo request :: ByteString
    okResponse =
      Wai.responseLBS
        HTTP.status200
        [ ("Content-Type", "text/plain; charset=utf-8")
        ]
        "ok"
