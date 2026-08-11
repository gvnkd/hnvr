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

    -- * Internal helpers (exported for unit tests; do not use outside)
    backoffDuration,
    countRecent,
    recordRestart,

    -- * Re-exports
    Transport (..),
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently)
import Control.Exception (SomeException, catch)
import Control.Monad (foldM, when)
import Crypto.Hash (Digest, SHA256 (..), hash)
import qualified Data.ByteArray as BA (convert)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Foldable (for_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef, writeIORef)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Hnvr.Capture.Ffmpeg (RecordingConfig (..), Transport (..), audioArgs, recordingArgs)
import Hnvr.Capture.Fmp4 (Fmp4State, Fragment (..), feed, finish, initial)
import Hnvr.Core.Id (CameraId, HostId, Sha256 (..))
import qualified Hnvr.Core.Logging as Log
import Hnvr.Core.Segment
  ( Segment (..),
    SegmentKind (..),
    toSegmentWritten,
  )
import Hnvr.Core.Time (formatSegmentObjectKeyMs, formatSegmentObjectKeyMsExt)
import Hnvr.Nats.Bus (Bus)
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Nats.Subjects (events)
import Hnvr.Storage.S3 (Bucket, putObjectBytes)
import Network.Minio (ConnectInfo, defaultPutObjectOptions, pooContentType)
import qualified System.Directory as Dir (createDirectoryIfMissing)
import System.Exit (ExitCode (..))
import System.IO (BufferMode (..), Handle, hSetBuffering)
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
    ccTransport :: !Transport,
    -- | When True, the worker spawns a second ffmpeg (audioArgs) in
    -- parallel to capture muxed audio as .m4a fragments. Per
    -- @03-capture-and-storage.md@ §3. Default False.
    ccRecordAudio :: !Bool
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

-- | One ffmpeg run cycle. Spawns the video ffmpeg (always) and, when
-- @ccRecordAudio@ is set, a second audio ffmpeg in parallel via
-- 'concurrently'. The exit code returned to the driver loop is the
-- video ffmpeg's — audio failures are isolated (logged, the audio
-- fragment for that segment is just absent from S3) so they don't
-- trigger worker-wide backoff.
--
-- Both ffmpegs read from the same RTSP source (typically
-- @rtsp://localhost:8554/<slug>@, the mediamtx internal relay that
-- became the single-puller point in M1.B). mediamtx holds the single
-- camera pull; multiple local ffmpegs just multiplex on its internal
-- fan-out so the camera's 1-session cap is never violated.
runOnce :: CaptureConfig -> CameraConfig -> IO ExitCode
runOnce cfg cam
  | ccRecordAudio cam = do
      (videoEc, _) <- concurrently (runOnceSingle False) (runOnceSingle True)
      pure videoEc
  | otherwise = runOnceSingle False
  where
    runOnceSingle isAudio = do
      let argsConfig =
            RecordingConfig
              { rcUrl = ccRtspUrl cam,
                rcTransport = ccTransport cam
              }
          args = if isAudio then audioArgs argsConfig else recordingArgs argsConfig
      when isAudio $ logInfo cam "spawning audio ffmpeg in parallel with video"
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
      processStream cfg cam isAudio hOut initial Nothing
      waitForProcess ph

-- | Stream ffmpeg's stdout through the Fmp4 parser, handling each emitted
-- fragment. Returns when stdout hits EOF.
--
-- The 'Maybe PendingFrag' is the previously-received fragment held back
-- so its 'sEnd' can be set to the wall-clock arrival time of the next
-- fragment (the standard HLS segmenter pattern). At EOF we flush it
-- with 'sEnd = now' as a best-effort bound.
--
-- @isAudio=True@ switches the S3 extension to @.m4a@ AND suppresses
-- the NATS publish (audio is uploaded but not indexed in the segments
-- table — v1 has no HLS audio integration; the data is preserved for
-- a future slice that adds @EXT-X-MEDIA@ audio groups to the
-- playlist).
processStream :: CaptureConfig -> CameraConfig -> Bool -> Handle -> Fmp4State -> Maybe PendingFrag -> IO ()
processStream cfg cam isAudio h st pending = do
  chunk <- B.hGetSome h 65_536
  if B.null chunk
    then do
      for_ (finish st) (handleFragment cfg cam isAudio pending)
      flushPending cfg cam isAudio pending
    else do
      let (frags, st') = feed st chunk
      newPending <- foldM (handleFragment cfg cam isAudio) pending frags
      processStream cfg cam isAudio h st' newPending

-- | A previously-received media fragment held back so we can stamp its
-- @sEnd@ when the next one arrives.
data PendingFrag = PendingFrag
  { pfStart :: !UTCTime,
    pfBytes :: !ByteString,
    pfSha :: !Sha256,
    pfKey :: !Text
  }

-- | Compute sha256, push to S3 (or spool), publish 'SegmentWritten' on
-- NATS (if Bus configured AND not the audio stream). Catches per-
-- fragment errors so one bad put doesn't kill the whole stream.
--
-- For 'MediaFragment', this enqueues the fragment as the new pending and
-- (if there was already a pending) publishes that one with
-- @sEnd = current wall-clock@. Returns the updated pending state.
--
-- @isAudio=True@ switches the S3 extension to @.m4a@ and suppresses the
-- NATS publish (audio is uploaded but not indexed in the segments table
-- — v1 has no HLS audio integration).
handleFragment :: CaptureConfig -> CameraConfig -> Bool -> Maybe PendingFrag -> Fragment -> IO (Maybe PendingFrag)
handleFragment cfg cam isAudio pending frag =
  case frag of
    InitFragment bs -> do
      let initName = if isAudio then "init.m4a" else "init.mp4"
          key = ccSlug cam <> "/" <> initName
      storeOrUpload cfg cam key bs "init"
      pure pending
    MediaFragment _tfdt bs -> do
      ts <- getCurrentTime
      let sha = sha256Bytes bs
          ext = if isAudio then "m4a" else "mp4"
          key = formatSegmentObjectKeyMsExt (ccSlug cam) ts ext
      -- Upload the current fragment immediately (S3 latency unchanged).
      storeOrUpload cfg cam key bs (if isAudio then "audio" else "media")
      -- Publish the previous pending (if any) now that we know its end.
      -- Audio path skips NATS — no DB rows for audio in v1.
      if isAudio
        then pure ()
        else flushPendingAt cfg cam ts pending
      pure (Just (PendingFrag ts bs sha key))
    `catch` \(e :: SomeException) -> do
      logErr cam $ "fragment handler failed: " <> show e
      pure pending

-- | Flush the pending fragment at EOF using the current wall-clock as
-- the best-effort @sEnd@. Audio path is a no-op (no pending was ever
-- recorded).
flushPending :: CaptureConfig -> CameraConfig -> Bool -> Maybe PendingFrag -> IO ()
flushPending cfg cam isAudio pending = do
  now <- getCurrentTime
  if isAudio
    then pure ()
    else flushPendingAt cfg cam now pending

-- | Publish the pending 'SegmentWritten' on @hnvr.events@ with the
-- supplied end timestamp. No-op if there is no pending fragment or no
-- Bus configured.
--
-- The object key comes from 'pfKey' — the exact key the fragment bytes
-- were uploaded under (millisecond precision, pitfall #25); recomputing
-- it here at second precision would point the DB row at a nonexistent
-- object.
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
       in Bus.publishJson bus events (toSegmentWritten (pfKey p) seg)
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

-- | Per-camera logger wrappers. Route through 'Hnvr.Core.Logging.logInfo'
-- / 'logError' so the process-global stdout lock prevents interleaved
-- output when multiple workers run concurrently. The format embeds the
-- camera slug as a prefix so the reader can grep a single camera's
-- lines out of the merged log.
logInfo, logErr :: CameraConfig -> String -> IO ()
logInfo cam msg = Log.logInfo ("[" <> ccSlug cam <> "] " <> T.pack msg)
logErr cam msg = Log.logError ("[" <> ccSlug cam <> "] " <> T.pack msg)
