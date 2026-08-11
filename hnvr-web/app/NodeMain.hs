{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Entry point for the @hnvr-node@ binary.
--
-- Runs on every host (including the leader host, which spawns both binaries).
-- Carries:
--
--   * CaptureSupervisor (one CaptureWorker per assigned camera) — M1.
--   * HealthReporter (publishes @hnvr.health.<host>@ every 5s)
--   * ConfigWatcher (subscribes @hnvr.commands.assign.>@,
--     @hnvr.commands.control.<host>.>@, and
--     @hnvr.config.cameras.>@; dispatches start/stop to the
--     CaptureSupervisor).
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
import qualified System.Environment as Env

-- | One-shot snapshot-request timeout (microseconds). Leader is
-- expected to reply within 5 s; if it doesn't, the node boots with an
-- empty worker set and will pick up cameras via subsequent
-- @hnvr.commands.assign@ messages.
snapshotTimeoutMicros :: Int
snapshotTimeoutMicros = 5_000_000

main :: IO ()
main = do
  let defaultUri = "nats://nats:nats@localhost:4222" :: Text
  uri <- maybe defaultUri T.pack <$> Env.lookupEnv "HNVR_NATS_URI"
  Bus.withBus Bus.defaultConfig {Bus.busUri = T.unpack uri} $ \bus -> do
    host <- maybe "hnvr-1" T.pack <$> Env.lookupEnv "HNVR_HOST"
    cfg <- buildCaptureConfig bus host
    sup <- startCaptureSupervisor cfg
    startHealthReporter bus host
    startConfigWatcher bus host sup
    logInfo ("node: connected to NATS: " <> uri)
    bootstrapFromSnapshot bus host sup
      `catch` \(e :: SomeException) ->
        logError ("node: snapshot bootstrap failed (will rely on assign messages): " <> T.pack (show e))
    void $ forever $ threadDelay 1000000000

-- | Construct the process-wide 'CaptureConfig' from environment.
-- Defaults match the devenv service wiring (MinIO on :9100,
-- @hnvr-recordings@ bucket, spool dir @/var/lib/hnvr/spool@).
buildCaptureConfig :: Bus -> Text -> IO CaptureConfig
buildCaptureConfig bus host = do
  mS3 <- readS3Config
  spool <- fromMaybe "/var/lib/hnvr/spool" <$> Env.lookupEnv "HNVR_SPOOL_DIR"
  pure
    CaptureConfig
      { capBus = Just bus,
        capS3 = S3.connectInfo <$> mS3,
        capBucket = maybe "hnvr-recordings" S3.s3cBucket mS3,
        capHostId = HostId host,
        capSpoolDir = spool
      }

-- | One-shot snapshot request to the leader. If we get a reply, spawn
-- a 'CaptureWorker' for each camera in the batch. If we don't (leader
-- down, snapshot responder not yet started, etc.), the node still
-- boots — subsequent @hnvr.commands.assign.<slug>@ messages will
-- populate the supervisor as the leader rebroadcasts assignments.
--
-- Note: this is called after 'startConfigWatcher' so any assign
-- messages that arrive between the snapshot reply and subsequent
-- updates are reconciled by the assign handler (idempotent
-- 'startCamera').
bootstrapFromSnapshot :: Bus -> Text -> CaptureSupervisor -> IO ()
bootstrapFromSnapshot bus host sup = do
  let subject = commandSnapshot host
      req = object ["host" .= host]
  mBatch <- Bus.requestJson bus subject req snapshotTimeoutMicros
  case mBatch :: Maybe CameraSnapshotBatch of
    Nothing -> logInfo "node: no snapshot reply (leader down or timed out); will rely on assign messages"
    Just batch -> do
      logInfo ("node: snapshot reply contained " <> T.pack (show (length (csbCameras batch))) <> " camera(s)")
      forM_ (csbCameras batch) (startCamera sup)

-- | Read S3 config from the standard @HNVR_S3_*@ env vars. Returns
-- 'Nothing' if any required var is missing — the supervisor still
-- starts but workers will spool locally instead of uploading.
readS3Config :: IO (Maybe S3.S3Config)
readS3Config = do
  let lookupText var = fmap T.pack <$> Env.lookupEnv var
  mEndpoint <- lookupText "HNVR_S3_ENDPOINT"
  mAccessKey <- lookupText "HNVR_S3_ACCESS_KEY"
  mSecretKey <- lookupText "HNVR_S3_SECRET_KEY"
  mBucket <- lookupText "HNVR_S3_BUCKET"
  pure $ do
    endpoint <- mEndpoint
    accessKey <- mAccessKey
    secretKey <- mSecretKey
    bucket <- mBucket
    Just
      S3.S3Config
        { S3.s3cEndpoint = endpoint,
          S3.s3cAccessKey = accessKey,
          S3.s3cSecretKey = secretKey,
          S3.s3cBucket = bucket
        }
