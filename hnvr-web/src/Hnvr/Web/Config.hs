{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE NumericUnderscores #-}
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
import Control.Monad (forM_, void, when)
import Data.Aeson (encode, object, (.=))
import Data.IORef (writeIORef)
import Data.Maybe (fromMaybe, maybe)
import qualified Data.Text as T
import Data.Time.Clock (diffUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Generated.Types
import Hnvr.Capture.Worker (CaptureConfig (..))
import Hnvr.Core.CameraSnapshot (CameraSnapshotBatch (..))
import Hnvr.Core.Id (HostId (..))
import Hnvr.Core.Logging (logError, logInfo)
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Nats.Subjects (commandSnapshot)
import Hnvr.Node.CaptureSupervisor (startCamera, startCaptureSupervisor)
import Hnvr.Node.ConfigWatcher (startConfigWatcher)
import Hnvr.Node.HealthReporter (startHealthReporter)
import qualified Hnvr.Storage.S3 as S3
import Hnvr.Web (version)
import Hnvr.Web.AssignmentCoordinator (startAssignmentCoordinator)
import Hnvr.Web.Auth ()
import Hnvr.Web.BusRegistry (busRegistry)
import Hnvr.Web.ConfigBroadcaster (startConfigBroadcaster)
import Hnvr.Web.DebugStream (debugStreamMiddleware)
import Hnvr.Web.EventWriter (startEventWriter)
import Hnvr.Web.HealthCache (startHealthCache)
import Hnvr.Web.MediaMTXConfigSyncer (startMediaMTXConfigSyncer)
import Hnvr.Web.Metrics (ensureMetrics, startGpuPoller, startMetricsServer)
import Hnvr.Web.PendingPurge (startPendingPurgeSweeper)
import Hnvr.Web.RetentionSweeper (startRetentionSweeper)
import Hnvr.Web.SnapshotResponder (startSnapshotResponder)
import Hnvr.Web.SupervisorRegistry (supervisorRegistry)
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
import qualified System.Timeout as Timeout

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

  -- IHP's `option` is FIRST-write-wins (IHP.FrameworkConfig:61 —
  -- `if TMap.member @option map then map else TMap.insert`), and
  -- `buildFrameworkConfig` runs `appConfig >> ihpDefaultConfig` so our
  -- `option`s land before the defaults. Calling `option $ CustomMiddleware`
  -- twice silently drops the second one. Compose all custom WAI
  -- middlewares here. Order: debug-stream runs first (most-specific path
  -- prefix), falls through to whep, /status, /healthz, then IHP.
  statusMw <- liftIO mkStatusMiddleware
  option $ CustomMiddleware (debugStreamMiddleware . whepMiddleware . statusMw . healthzMiddleware)
  option $ AuthMiddleware (authMiddleware @User)
  addInitializer connectNatsAndStartEventWriter
  addInitializer seedAdminUser
  -- Metrics store + Prometheus endpoint + GPU poller. Runs outside the
  -- IHP middleware chain (own warp on HNVR_METRICS_PORT) so the node
  -- binary can share the same code path. Best-effort: a port clash
  -- (e.g. two dev leaders) must not take the leader down.
  liftIO (gated "HNVR_DISABLE_METRICS" startMetricsStack)

-- | Bring up the metrics stack (store + /metrics warp + GPU poller).
-- Failures are logged, never fatal.
startMetricsStack :: IO ()
startMetricsStack = do
  (store, _) <- ensureMetrics
  startMetricsServer store
    `E.catch` \(e :: E.SomeException) ->
      logError ("leader: metrics server start failed: " <> cs (show e))
  startGpuPoller store

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
  gated "HNVR_DISABLE_MEDIAMTX" startMediaMTXConfigSyncer
  -- Retention sweep also independent of NATS (just PG + S3). Best-effort.
  gated "HNVR_DISABLE_RETENTION" startRetentionSweeper
  -- Verified-delete sweeper (tombstoned segments → S3 purge → row
  -- DELETE). Same PG+S3-only profile as the retention sweep.
  gated "HNVR_DISABLE_PENDINGPURGE" startPendingPurgeSweeper
  let defaultUri = "nats://nats:nats@localhost:4222"
  uri <- fromMaybe defaultUri <$> Env.lookupEnv "HNVR_NATS_URI"
  let connect' = do
        bus <- Bus.connect Bus.defaultConfig {Bus.busUri = uri}
        writeIORef busRegistry (Just bus)
        logInfo ("leader: connected to NATS: " <> cs (uri :: String))
        gated "HNVR_DISABLE_EVENTWRITER" (startEventWriter bus ?modelContext)
        gated "HNVR_DISABLE_HEALTHCACHE" (void (startHealthCache bus))
        gated "HNVR_DISABLE_COORDINATOR" (startAssignmentCoordinator bus)
        gated "HNVR_DISABLE_BROADCASTER" (startConfigBroadcaster bus)
        -- Leader-only: respond to node snapshot requests so workers
        -- can bootstrap their initial camera set on boot.
        gated "HNVR_DISABLE_SNAPSHOTRESPONDER" (startSnapshotResponder bus)
        -- Leader also runs the full node role (CaptureSupervisor +
        -- ConfigWatcher + HealthReporter) per @01-architecture.md:21@
        -- — "leader = all of node + leader roles".
        host <- maybe "hnvr-2" T.pack <$> Env.lookupEnv "HNVR_HOST"
        gated "HNVR_DISABLE_NODEROLES" (startNodeRoles bus host)
        gated "HNVR_DISABLE_HEALTHREPORTER" (startHealthReporter bus host)
  connect' `E.catch` \(e :: E.SomeException) ->
    logError ("leader: NATS connect failed (continuing without bus): " <> cs (show e))

-- | Leak-bisect kill switch: run the action unless the named env var
-- is set to "1". Logs the skip so a forgotten toggle is visible.
gated :: String -> IO () -> IO ()
gated var act = do
  off <- (== Just "1") <$> Env.lookupEnv var
  if off
    then logInfo ("leader: " <> cs var <> "=1 — component disabled")
    else
      act `E.catch` \(e :: E.SomeException) ->
        logError ("leader: component start failed (" <> cs var <> "): " <> cs (show e))

-- | Wire the node-side roles on the leader: build CaptureConfig from
-- env, start the CaptureSupervisor, subscribe ConfigWatcher, and
-- request the initial snapshot from ourselves (we ARE the leader, so
-- the SnapshotResponder replies locally). Best-effort — failures here
-- don't crash the leader.
startNodeRoles :: Bus.Bus -> Text -> IO ()
startNodeRoles bus host = do
  mS3 <- S3.readS3ConfigFromEnv
  spool <- fromMaybe "/var/lib/hnvr/spool" <$> Env.lookupEnv "HNVR_SPOOL_DIR"
  (_, metrics) <- ensureMetrics
  let cfg =
        CaptureConfig
          { capBus = Just bus,
            capS3 = S3.connectInfo <$> mS3,
            capBucket = maybe "hnvr-recordings" S3.s3cBucket mS3,
            capHostId = HostId host,
            capSpoolDir = spool,
            capMetrics = metrics
          }
  sup <- startCaptureSupervisor cfg
  writeIORef supervisorRegistry (Just sup)
  startConfigWatcher bus host sup
  let subject = commandSnapshot host
      req = object ["host" .= host]
  mBatch <- Timeout.timeout 5_000_000 (Bus.requestJson bus subject req 5_000_000)
  case mBatch :: Maybe (Maybe CameraSnapshotBatch) of
    Just (Just batch) -> do
      logInfo ("leader: local snapshot reply contained " <> cs (show (length (csbCameras batch))) <> " camera(s)")
      forM_ (csbCameras batch) (startCamera sup)
    _ -> logInfo "leader: no local snapshot reply (continuing)"

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

-- | Build the @/status@ middleware: unauthenticated JSON system-status
-- page carrying the package version (from hnvr-web.cabal via
-- 'Hnvr.Web.version'), the host name (@HNVR_HOST@), process start time
-- and uptime. Start time + host are captured once at boot; uptime is
-- computed per request.
mkStatusMiddleware :: IO Wai.Middleware
mkStatusMiddleware = do
  started <- getCurrentTime
  host <- Env.lookupEnv "HNVR_HOST"
  pure $ \app request respond ->
    if Wai.rawPathInfo request == "/status"
      then do
        now <- getCurrentTime
        let uptime = floor (diffUTCTime now started) :: Int
            body =
              encode
                $ object
                  [ "app" .= ("hnvr" :: Text),
                    "version" .= version,
                    "host" .= fmap T.pack host,
                    "startedAt" .= iso8601Show started,
                    "uptimeSeconds" .= uptime
                  ]
        respond
          $ Wai.responseLBS
            HTTP.status200
            [("Content-Type", "application/json; charset=utf-8")]
            body
      else app request respond
