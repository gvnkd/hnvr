{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Entry point for the @hnvr-node@ binary.
--
-- Runs on WORKER hosts only. Do NOT run it on the leader host: the
-- leader binary already embeds the full node role for its own
-- @HNVR_HOST@ (@Hnvr.Web.Config.startNodeRoles@, per
-- @01-architecture.md@ "leader = all of node + leader roles"). Running
-- both was the 2026-08-15 double-record bug (duplicate fragments,
-- 1–2 s playback jump-backs). The snapshot-claim handshake below
-- ('Hnvr.Core.HostClaim') refuses to start workers in that case.
--
-- Carries:
--
--   * CaptureSupervisor (one CaptureWorker per assigned camera) — M1.
--   * HealthReporter (publishes @hnvr.health.<host>@ every 5s)
--   * ConfigWatcher (subscribes @hnvr.commands.assign.>@,
--     @hnvr.commands.control.<host>.>@, and
--     @hnvr.config.cameras.>@; dispatches start/stop to the
--     CaptureSupervisor). Started ONLY after the snapshot claim is
--     granted, so a denied node never reacts to assign broadcasts.
--
-- No HTTP server. No Postgres credentials (only NATS + S3 creds).
-- Learns its initial camera set via a one-shot NATS request/reply to
-- @hnvr.commands.snapshot.<host>@ (handled by the leader's
-- 'Hnvr.Web.SnapshotResponder').
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, catch)
import Control.Monad (forM_, forever, void)
import Data.Aeson (object, (.=))
import Data.Maybe (fromMaybe, maybe)
import Data.Text (Text)
import qualified Data.Text as T
import Hnvr.Capture.Worker (CaptureConfig (..))
import Hnvr.Core.CameraSnapshot (CameraSnapshotBatch (..))
import Hnvr.Core.Id (HostId (..))
import Hnvr.Core.Logging (logError, logInfo)
import Hnvr.Core.Metrics (Metrics)
import Hnvr.Nats.Bus (Bus)
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Nats.Subjects (commandSnapshot)
import Hnvr.Node.CaptureSupervisor
  ( CaptureSupervisor,
    startCamera,
    startCaptureSupervisor,
  )
import Hnvr.Node.ConfigWatcher (startConfigWatcher)
import Hnvr.Node.HealthReporter (startHealthReporter)
import qualified Hnvr.Storage.S3 as S3
import Hnvr.Web (versionText)
import Hnvr.Web.Metrics (ensureMetrics, startGpuPoller, startMetricsServer)
import qualified System.Environment as Env

-- | One-shot snapshot-request timeout (microseconds). Leader is
-- expected to reply within 5 s; if it doesn't, the node boots with an
-- empty worker set and will pick up cameras via subsequent
-- @hnvr.commands.assign@ messages.
snapshotTimeoutMicros :: Int
snapshotTimeoutMicros = 5_000_000

main :: IO ()
main = do
  logInfo ("starting hnvr-node, " <> versionText)
  let defaultUri = "nats://nats:nats@localhost:4222" :: Text
  (metricsStore, metrics) <- ensureMetrics
  startMetricsServer metricsStore
  startGpuPoller metricsStore
  uri <- maybe defaultUri T.pack <$> Env.lookupEnv "HNVR_NATS_URI"
  Bus.withBus Bus.defaultConfig {Bus.busUri = T.unpack uri} $ \bus -> do
    host <- maybe "hnvr-1" T.pack <$> Env.lookupEnv "HNVR_HOST"
    cfg <- buildCaptureConfig bus host metrics
    sup <- startCaptureSupervisor cfg
    startHealthReporter bus host
    logInfo ("node: connected to NATS: " <> uri)
    -- Claim FIRST: the ConfigWatcher must not run before we own this
    -- host, or a node accidentally started on the leader host would
    -- react to assign broadcasts and double-record every camera.
    batch <- claimHost bus host
    startConfigWatcher bus host sup
    logInfo ("node: snapshot reply contained " <> T.pack (show (length (csbCameras batch))) <> " camera(s)")
    forM_ (csbCameras batch) (startCamera sup)
    void $ forever $ threadDelay 1_000_000_000

-- | Construct the process-wide 'CaptureConfig' from environment.
-- Defaults match the devenv service wiring (MinIO on :9100,
-- @hnvr-recordings@ bucket, spool dir @/var/lib/hnvr/spool@).
buildCaptureConfig :: Bus -> Text -> Metrics -> IO CaptureConfig
buildCaptureConfig bus host metrics = do
  mS3 <- S3.readS3ConfigFromEnv
  spool <- fromMaybe "/var/lib/hnvr/spool" <$> Env.lookupEnv "HNVR_SPOOL_DIR"
  pure
    CaptureConfig
      { capBus = Just bus,
        capS3 = S3.connectInfo <$> mS3,
        capBucket = maybe "hnvr-recordings" S3.s3cBucket mS3,
        capHostId = HostId host,
        capSpoolDir = spool,
        capMetrics = metrics
      }

-- | Request the snapshot/claim from the leader, retrying every 30 s
-- until granted. Three non-granted outcomes:
--
--   * no reply (leader down, responder not yet started) — retry;
--   * decode failure (leader older than the @claimed@ field — the node
--     treats it as denied, safe direction: idle, never double-record);
--   * explicit denial (@claimed: false@ — this host is owned by the
--     leader's embedded worker; running hnvr-node here was the
--     2026-08-15 double-record bug).
--
-- Retrying doubles as a liveness wait: the node starts working as soon
-- as a leader comes up, without relying on missed assign broadcasts.
claimHost :: Bus -> Text -> IO CameraSnapshotBatch
claimHost bus host = go
  where
    subject = commandSnapshot host
    req = object ["host" .= host]
    go = do
      mBatch <-
        Bus.requestJson bus subject req snapshotTimeoutMicros
          `catch` \(e :: SomeException) -> do
            logError ("node: snapshot request failed: " <> T.pack (show e))
            pure Nothing
      case mBatch :: Maybe CameraSnapshotBatch of
        Just batch
          | csbClaimed batch -> pure batch
          | otherwise -> do
              logError
                ( "node: snapshot claim DENIED for "
                    <> host
                    <> " — this host is owned by the leader's embedded worker; \
                       \do not run hnvr-node on the leader host. Retrying in 30s."
                )
              retry
        Nothing -> do
          logInfo "node: no snapshot reply (leader down or pre-claim leader build); retrying in 30s"
          retry
    retry = threadDelay 30_000_000 >> go
