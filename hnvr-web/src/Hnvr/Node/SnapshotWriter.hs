{-# LANGUAGE OverloadedStrings #-}

-- | Periodic per-camera snapshot writer (archive-timeline thumbnail
-- store, design_docs/12-timeline-archive.md, Phase A).
--
-- Tapped from 'Hnvr.Node.CaptureSupervisor.analysisSink' once per
-- analyzed frame; emits at most one snapshot per camera per
-- @cameras.snapshot_interval_sec@ (0 = disabled). The due-check is a
-- cheap STM map lookup; the JPEG encode + S3 upload + NATS publish run
-- on a forked thread so the analyzer loop never blocks on storage.
-- Failures log and drop — a missing snapshot is a UI gap, not a data
-- problem, and the next interval retries.
--
-- Kill switch: @HNVR_DISABLE_SNAPSHOTWRITER=1@ (read once at supervisor
-- start; same pattern as the other role gates).
module Hnvr.Node.SnapshotWriter
  ( SnapshotState,
    newSnapshotState,
    maybeSnapshot,
  )
where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, writeTVar)
import Control.Exception (SomeException, try)
import Control.Monad (void, when)
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, diffUTCTime)
import Hnvr.Capture.Worker (CaptureConfig (..))
import Hnvr.Core.CameraSnapshot (CameraSnapshot (..))
import Hnvr.Core.Event (SnapshotWritten (..))
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Core.Id (CameraId)
import Hnvr.Core.Logging (logWarn)
import Hnvr.Core.Time (formatYmdHmsMs)
import Hnvr.Cv.DebugRender (renderJpeg)
import qualified Hnvr.Nats.Bus as Bus
import qualified Hnvr.Nats.Subjects as Subjects
import Hnvr.Storage.S3 (putObjectBytes)
import Network.Minio (defaultPutObjectOptions, pooContentType)

-- | Per-camera last-attempt timestamps. Attempt time (not success) is
-- recorded so a failing S3 endpoint doesn't get hammered at analysis
-- fps — retries happen on the next interval like everything else.
newtype SnapshotState = SnapshotState (TVar (Map CameraId UTCTime))

newSnapshotState :: IO SnapshotState
newSnapshotState = SnapshotState <$> newTVarIO M.empty

-- | JPEG quality for snapshot uploads. 75 keeps a 640x360 frame in the
-- 30-50 kB range — legible for timeline scrubbing, cheap to store at
-- one frame per minute per camera.
jpegQuality :: Int
jpegQuality = 75

-- | Due-check + forked upload. Called from the analysis sink on every
-- analyzed frame; returns immediately when snapshots are disabled for
-- the camera (@csSnapshotIntervalSec <= 0@), when the interval hasn't
-- elapsed, or when S3/NATS aren't configured.
maybeSnapshot :: SnapshotState -> CaptureConfig -> CameraSnapshot -> Frame -> IO ()
maybeSnapshot (SnapshotState tv) cfg snap frame
  | interval <= 0 = pure ()
  | otherwise = case (capS3 cfg, capBus cfg) of
      (Just ci, Just bus) -> do
        due <- atomically $ do
          m <- readTVar tv
          case M.lookup camId m of
            Just lastTs
              | diffUTCTime now lastTs < fromIntegral interval -> pure False
            _ -> do
              writeTVar tv (M.insert camId now m)
              pure True
        when due $ void $ forkIO $ uploadAndPublish ci bus
      _ -> pure ()
  where
    interval = csSnapshotIntervalSec snap
    camId = csId snap
    now = frameTimestamp frame
    key = csSlug snap <> "/snapshots/" <> formatYmdHmsMs now <> ".jpg"
    jpg = renderJpeg jpegQuality frame
    uploadAndPublish ci bus = do
      let opts = defaultPutObjectOptions {pooContentType = Just "image/jpeg"}
      r <-
        try (putObjectBytes ci (capBucket cfg) key (BL.toStrict jpg) opts) ::
          IO (Either SomeException ())
      case r of
        Left e ->
          logWarn ("SnapshotWriter: upload failed for " <> csSlug snap <> ": " <> T.pack (show e))
        Right () ->
          Bus.publishJson bus Subjects.events $
            SnapshotWritten
              { snCamera = camId,
                snTs = now,
                snObjectKey = key,
                snBytes = fromIntegral (BL.length jpg),
                snHost = capHostId cfg
              }
