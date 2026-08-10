{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Per-camera capture worker state machine.
--
-- Drives the lifecycle of one recording ffmpeg:
--
--   * @Pending@           → @Running@: open NATS pub, prime spool dir, spawn ffmpeg.
--   * @Running@           → @Backoff n@: ffmpeg exited (cleanly or otherwise).
--   * @Backoff n@         → @Pending@: after exponential delay (2/4/8/16/30s).
--   * 5 failures / 60s    → @FailedPermanent@: alert + retry every 5 min.
--   * @FailedPermanent@   → @Pending@: after 5-min cooldown.
--   * @Stopped@           → exit worker (cross-host reassignment command).
--
-- While @Running, the worker reads ffmpeg's stdout pipe, slices it into
-- fMP4 fragments via "Hnvr.Capture.Fmp4", uploads each to SeaweedFS via
-- "Hnvr.Storage.S3", and publishes a 'SegmentWritten' envelope on
-- @hnvr.events@ via "Hnvr.Nats.Bus". Spool-on-S3-outage (design §3
-- \"Spool on S3 outage\") lands in a follow-up slice; for now S3 failures
-- are logged and the fragment is dropped.
--
-- The analysis ffmpeg (sub-stream → RGB frames) lands with the CV
-- pipeline in Phase 3; this module is record-only.
module Hnvr.Capture.Worker
  ( -- * Configuration
    CameraConfig (..),
    CaptureConfig (..),
    CaptureState (..),

    -- * Entry point
    captureWorker,
    captureWorkerWithStop,

    -- * Re-exports
    Transport (..),
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, catch)
import Control.Monad (foldM)
import Crypto.Hash (Digest, SHA256 (..), hash)
import qualified Data.ByteArray as BA (convert)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Hnvr.Capture.Ffmpeg (RecordingConfig (..), Transport (..), recordingArgs)
import Hnvr.Capture.Fmp4 (Fmp4State, Fragment (..), feed, finish, initial)
import Hnvr.Core.Id (CameraId, HostId, Sha256 (..))
import Hnvr.Core.Segment
  ( Segment (..),
    SegmentKind (..),
    toSegmentWritten,
  )
import Hnvr.Core.Time (formatSegmentObjectKeyMs)
import Hnvr.Nats.Bus (Bus)
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Nats.Subjects (events)
import Hnvr.Storage.S3 (Bucket, putObjectBytes)
import Network.Minio (ConnectInfo, defaultPutObjectOptions, pooContentType)
import qualified System.Directory as Dir (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.IO (BufferMode (..), Handle, hPutStrLn, hSetBuffering, stderr)
import System.Process
  ( CreateProcess (..),
    StdStream (..),
    createProcess,
    proc,
    waitForProcess,
  )

-- | Per-camera static config (subset of the eventual @cameras@ row that
-- the worker needs at startup). The CameraId is for NATS payloads;
-- @ccSlug@ is for S3 object keys + logs.
data CameraConfig = CameraConfig
  { ccId :: !CameraId,
    ccSlug :: !Text,
    ccRtspUrl :: !Text,
    ccTransport :: !Transport
  }
  deriving stock (Eq, Show)

-- | Process-wide config shared by all workers on a host. @Maybe@ fields
-- allow running in degraded modes (e.g. S3 down → spool only; NATS down →
-- silent).
data CaptureConfig = CaptureConfig
  { -- | NATS bus for publishing 'SegmentWritten'. 'Nothing' = silent.
    capBus :: !(Maybe Bus),
    -- | SeaweedFS/MinIO connection. 'Nothing' = local-disk only.
    capS3 :: !(Maybe ConnectInfo),
    capBucket :: !Bucket,
    capHostId :: !HostId,
    -- | Local spool when S3 is unreachable (or 'capS3' is 'Nothing').
    capSpoolDir :: !FilePath
  }

-- No auto-derived Show/Eq because @Bus@ (nats-queue Nats handle) has
-- neither; use field accessors if you need to log this.

-- | Worker lifecycle state. The driver loop reads + transitions this.
-- Observability tools (EKG, /healthz) read the same IORef.
data CaptureState
  = Pending
  | Running
  | -- | retry count + next-retry-at
    Backoff !Int !UTCTime
  | -- | next-retry-at
    FailedPermanent !UTCTime
  | Stopped
  deriving stock (Eq, Show)

-- | Top-level worker. Runs forever (until killed or commanded to
-- 'Stopped' via the 'captureWorkerWithStop' variant). Catches all
-- exceptions inside @runOnce@ to keep the driver alive.
captureWorker :: CaptureConfig -> CameraConfig -> IO ()
captureWorker cfg cam = captureWorkerWithStop cfg cam (pure False)

-- | Like 'captureWorker' but polls the supplied @shouldStop@ IO action
-- between state transitions; returns when it returns 'True'.
captureWorkerWithStop :: CaptureConfig -> CameraConfig -> IO Bool -> IO ()
captureWorkerWithStop cfg cam shouldStop = do
  stRef <- newIORef Pending
  recentRef <- newIORef ([] :: [UTCTime])
  logInfo cam "starting worker"
  driver stRef recentRef
  where
    driver stRef recentRef = do
      stop <- shouldStop
      if stop
        then logInfo cam "stop signal received; exiting"
        else do
          st <- readIORef stRef
          next <- transition cfg cam recentRef st
          writeIORef stRef next
          driver stRef recentRef

-- | Single state-machine transition. Returns the next state. Side-effects
-- (ffmpeg spawn, backoff sleeps, etc.) happen here.
transition :: CaptureConfig -> CameraConfig -> IORef [UTCTime] -> CaptureState -> IO CaptureState
transition cfg cam recentRef = \case
  Pending -> do
    logInfo cam "Pending → Running"
    ec <-
      runOnce cfg cam `catch` \(e :: SomeException) -> do
        logErr cam $ "runOnce threw: " <> show e
        pure (ExitFailure 99)
    now <- getCurrentTime
    recordRestart recentRef now
    n <- countRecent recentRef now
    if n >= 5
      then do
        logErr cam $ "5 restarts within 60s → FailedPermanent (last ec=" <> show ec <> ")"
        pure (FailedPermanent (addUTCTime 300 now))
      else do
        let dur = backoffDuration n
        logInfo cam $ "ffmpeg exit " <> show ec <> " → Backoff #" <> show n <> " for " <> show dur <> "s"
        pure (Backoff n (addUTCTime (fromIntegral dur) now))
  Running -> do
    -- Should not happen in normal driver loop (runOnce blocks until ffmpeg
    -- exits, returning Pending-via-Backoff). Defensive: re-poll.
    pure Pending
  Backoff n nextAt -> do
    now <- getCurrentTime
    if now >= nextAt
      then pure Pending
      else do
        threadDelay 1_000_000 -- 1s poll
        pure (Backoff n nextAt)
  FailedPermanent nextAt -> do
    now <- getCurrentTime
    if now >= nextAt
      then do
        -- Reset restart budget for a fresh 5/60s window.
        writeIORef recentRef []
        logInfo cam "FailedPermanent cooldown elapsed → Pending"
        pure Pending
      else do
        threadDelay 5_000_000 -- 5s poll
        pure (FailedPermanent nextAt)
  Stopped -> pure Stopped

-- | One ffmpeg run cycle. Spawns ffmpeg, streams stdout into the Fmp4
-- parser, handles each emitted fragment (sha256 + S3 put + NATS publish),
-- waits for ffmpeg exit. Returns the exit code; never throws (caller
-- wraps in `catch`).
runOnce :: CaptureConfig -> CameraConfig -> IO ExitCode
runOnce cfg cam = do
  let args =
        recordingArgs
          RecordingConfig
            { rcUrl = ccRtspUrl cam,
              rcTransport = ccTransport cam
            }
  (_, mOut, _, ph) <-
    createProcess
      (proc "ffmpeg" args)
        { std_out = CreatePipe,
          std_err = Inherit
        }
  hOut <- case mOut of
    Just h -> pure h
    Nothing -> fail "ffmpeg did not give us a stdout pipe"
  hSetBuffering hOut (BlockBuffering (Just 65_536))
  processStream cfg cam hOut initial Nothing
  waitForProcess ph

-- | Stream ffmpeg's stdout through the Fmp4 parser, handling each emitted
-- fragment. Returns when stdout hits EOF.
--
-- The 'Maybe PendingFrag' is the previously-received fragment held back
-- so its 'sEnd' can be set to the wall-clock arrival time of the next
-- fragment (the standard HLS segmenter pattern). At EOF we flush it
-- with 'sEnd = now' as a best-effort bound.
processStream :: CaptureConfig -> CameraConfig -> Handle -> Fmp4State -> Maybe PendingFrag -> IO ()
processStream cfg cam h st pending = do
  chunk <- B.hGetSome h 65_536
  if B.null chunk
    then do
      for_ (finish st) (handleFragment cfg cam pending)
      flushPending cfg cam pending
    else do
      let (frags, st') = feed st chunk
      newPending <- foldM (handleFragment cfg cam) pending frags
      processStream cfg cam h st' newPending

-- | A previously-received media fragment held back so we can stamp its
-- @sEnd@ when the next one arrives.
data PendingFrag = PendingFrag
  { pfStart :: !UTCTime,
    pfBytes :: !ByteString,
    pfSha :: !Sha256
  }

-- | Compute sha256, push to S3 (or spool), publish 'SegmentWritten' on
-- NATS (if Bus configured). Catches per-fragment errors so one bad put
-- doesn't kill the whole stream.
--
-- For 'MediaFragment', this enqueues the fragment as the new pending and
-- (if there was already a pending) publishes that one with
-- @sEnd = current wall-clock@. Returns the updated pending state.
handleFragment :: CaptureConfig -> CameraConfig -> Maybe PendingFrag -> Fragment -> IO (Maybe PendingFrag)
handleFragment cfg cam pending frag =
  case frag of
    InitFragment bs -> do
      let key = ccSlug cam <> "/init.mp4"
      storeOrUpload cfg cam key bs "init"
      pure pending
    MediaFragment _tfdt bs -> do
      ts <- getCurrentTime
      let sha = sha256Bytes bs
          key = formatSegmentObjectKeyMs (ccSlug cam) ts
      -- Upload the current fragment immediately (S3 latency unchanged).
      storeOrUpload cfg cam key bs "media"
      -- Publish the previous pending (if any) now that we know its end.
      flushPendingAt cfg cam ts pending
      pure (Just (PendingFrag ts bs sha))
    `catch` \(e :: SomeException) -> do
      logErr cam $ "fragment handler failed: " <> show e
      pure pending

-- | Flush the pending fragment at EOF using the current wall-clock as
-- the best-effort @sEnd@.
flushPending :: CaptureConfig -> CameraConfig -> Maybe PendingFrag -> IO ()
flushPending cfg cam pending = do
  now <- getCurrentTime
  flushPendingAt cfg cam now pending

-- | Publish the pending 'SegmentWritten' on @hnvr.events@ with the
-- supplied end timestamp. No-op if there is no pending fragment or no
-- Bus configured.
flushPendingAt :: CaptureConfig -> CameraConfig -> UTCTime -> Maybe PendingFrag -> IO ()
flushPendingAt cfg cam endTs pending =
  case (capBus cfg, pending) of
    (Just bus, Just p) ->
      let seg =
            Segment
              { sCamera = ccId cam,
                sSlug = ccSlug cam,
                sStart = pfStart p,
                sEnd = endTs,
                sBytes = pfBytes p,
                sSha = pfSha p,
                sKind = Video,
                sHostId = capHostId cfg
              }
       in Bus.publishJson bus events (toSegmentWritten seg)
    _ -> pure ()

-- | Upload to S3 if configured; otherwise write to the local spool dir.
-- Failure to upload logs an error and falls back to spool (so we don't
-- drop segments on transient S3 blips).
storeOrUpload :: CaptureConfig -> CameraConfig -> Text -> ByteString -> String -> IO ()
storeOrUpload cfg cam keyBytes bytes kind = do
  case capS3 cfg of
    Just ci -> do
      let opts = defaultPutObjectOptions {pooContentType = Just "video/mp4"}
      putObjectBytes ci (capBucket cfg) keyBytes bytes opts
        `catch` \(e :: SomeException) -> do
          logErr cam $ "S3 put failed (" <> kind <> "), spooling locally: " <> show e
          spoolLocally cfg keyBytes bytes
    Nothing -> spoolLocally cfg keyBytes bytes

-- | Fallback: write the fragment bytes to the spool directory using the
-- same key path. The (future) SpoolDrainer re-uploads when S3 returns.
spoolLocally :: CaptureConfig -> Text -> ByteString -> IO ()
spoolLocally cfg keyBytes bytes = do
  let p = capSpoolDir cfg <> "/" <> T.unpack keyBytes
      dir = reverse (dropWhile (/= '/') (reverse p))
  Dir.createDirectoryIfMissing True dir
  B.writeFile p bytes

-- | Publish a 'SegmentWritten' on @hnvr.events@ if a Bus is configured.
-- Object key is recomputed by `toSegmentWritten` from slug + start time,
-- so callers don't need to thread it through.
--
-- Note: actual publishing now happens in 'flushPendingAt' so we can stamp
-- @sEnd = next fragment arrival@. Kept here as a documentation hook;
-- callers wanting a one-shot publish with explicit timestamps should use
-- 'Bus.publishJson' directly with a fully-populated 'Segment'.

-- | Exponential backoff (seconds): 2, 4, 8, 16, 30, 30, 30, ...
backoffDuration :: Int -> Int
backoffDuration n
  | n <= 0 = 2
  | n >= 5 = 30
  | otherwise = min 30 (2 ^ n)

-- | Record a restart timestamp.
recordRestart :: IORef [UTCTime] -> UTCTime -> IO ()
recordRestart ref now =
  modifyIORef' ref (now :)

-- | Count restarts within the last 60 seconds.
countRecent :: IORef [UTCTime] -> UTCTime -> IO Int
countRecent ref now = do
  rs <- readIORef ref
  let cutoff = addUTCTime (-60) now
      recent = filter (>= cutoff) rs
  writeIORef ref recent
  pure (length recent)

-- | SHA-256 of a strict ByteString, returned as raw 32 bytes.
sha256Bytes :: ByteString -> Sha256
sha256Bytes bs = Sha256 (BA.convert (hash bs :: Digest SHA256))

logInfo, logErr :: CameraConfig -> String -> IO ()
logInfo cam msg = hPutStrLn stderr ("[" <> T.unpack (ccSlug cam) <> " INFO] " <> msg)
logErr cam msg = hPutStrLn stderr ("[" <> T.unpack (ccSlug cam) <> " ERROR] " <> msg)
