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

    -- * Observability
    captureStateWire,

    -- * Internal helpers (exported for unit tests; do not use outside)
    transition,
    backoffDuration,
    countRecent,
    recordRestart,

    -- * Re-exports
    Transport (..),
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, writeTVar)
import Control.Exception (SomeAsyncException (..), SomeException, bracket, catch, fromException, throwIO)
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
import Hnvr.Capture.Process (reapProcess)
import Hnvr.Capture.RingBuffer (RingBuffer)
import qualified Hnvr.Capture.RingBuffer as RB
import Hnvr.Core.CameraStatus (CaptureStateWire (..))
import Hnvr.Core.Id (CameraId, HostId, Sha256 (..))
import qualified Hnvr.Core.Logging as Log
import Hnvr.Core.Metrics (Metrics)
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
    -- | When True, the recording ffmpeg muxes the camera's audio track
    -- (band-passed 60 Hz – 14 kHz, re-encoded to AAC) into the video
    -- fragments — see 'Hnvr.Capture.Ffmpeg.recordingArgs'. Default False.
    ccRecordAudio :: !Bool,
    -- | Camera's real audio sampling rate (Hz) for fixed-clock codecs
    -- (G.711/G.726 at ≠8 kHz — see 'Hnvr.Core.CameraSnapshot.audioInputRateHz').
    -- 'Nothing' = trust the SDP clock.
    ccAudioInputRateHz :: !(Maybe Int),
    -- | Rolling fragment buffer feeding the event-clip recorder
    -- ('Hnvr.Capture.RingBuffer'). 'Nothing' when no clip-enabled rule
    -- exists for the camera — zero overhead in that case. Shared (STM)
    -- between this worker (writer) and the clip recorder (reader).
    ccClipBuffer :: !(Maybe (TVar RingBuffer))
  }

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
    capSpoolDir :: !FilePath,
    -- | Instrumentation hooks ('Hnvr.Core.Metrics.noOpMetrics' when
    -- metrics are disabled).
    capMetrics :: !Metrics
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
captureWorker cfg cam = do
  stateVar <- newTVarIO Pending
  captureWorkerWithStop cfg cam (pure False) stateVar

-- | Like 'captureWorker' but polls the supplied @shouldStop@ IO action
-- between state transitions; returns when it returns 'True'.
--
-- The @stateVar@ mirrors the worker's current 'CaptureState' (including
-- 'Running', which the internal driver IORef never holds — @runOnce@
-- blocks inside the 'Pending' transition). The CaptureSupervisor keeps
-- one per camera so the HealthReporter can publish real per-camera
-- states; before this, worker failures were log-only and the UI kept
-- showing dead cameras as recording.
captureWorkerWithStop :: CaptureConfig -> CameraConfig -> IO Bool -> TVar CaptureState -> IO ()
captureWorkerWithStop cfg cam shouldStop stateVar = do
  stRef <- newIORef Pending
  recentRef <- newIORef ([] :: [UTCTime])
  logInfo cam "starting worker"
  driver stRef recentRef
  where
    driver stRef recentRef = do
      stop <- shouldStop
      if stop
        then do
          atomically (writeTVar stateVar Stopped)
          logInfo cam "stop signal received; exiting"
        else do
          st <- readIORef stRef
          next <- transition stateVar cfg cam recentRef st
          writeIORef stRef next
          atomically (writeTVar stateVar next)
          driver stRef recentRef

-- | Phase-only projection onto the health-payload wire format
-- ('Hnvr.Core.CameraStatus').
captureStateWire :: CaptureState -> CaptureStateWire
captureStateWire = \case
  Pending -> WPending
  Running -> WRunning
  Backoff _ _ -> WBackoff
  FailedPermanent _ -> WFailed
  Stopped -> WStopped

-- | Single state-machine transition. Returns the next state. Side-effects
-- (ffmpeg spawn, backoff sleeps, etc.) happen here. Writes 'Running'
-- into @stateVar@ while @runOnce@ blocks (the driver's own write after
-- 'transition' returns only covers the non-blocking states).
transition :: TVar CaptureState -> CaptureConfig -> CameraConfig -> IORef [UTCTime] -> CaptureState -> IO CaptureState
transition stateVar cfg cam recentRef = \case
  Pending -> do
    logInfo cam "Pending → Running"
    atomically (writeTVar stateVar Running)
    ec <-
      runOnce cfg cam `catch` \(e :: SomeException) -> do
        -- Cancellation must propagate — swallowing it would turn a
        -- stop into an infinite ffmpeg-respawn loop and hang @cancel@.
        case fromException e of
          Just (SomeAsyncException _) -> throwIO e
          Nothing -> pure ()
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

-- | One ffmpeg run cycle. Spawns the recording ffmpeg; when
-- @ccRecordAudio@ is set the same ffmpeg also muxes the camera's audio
-- track (filtered + AAC) into the fragments, so audio failures are
-- impossible to isolate from video ones — the whole stream restarts
-- together, which is what we want: a silent fragment stream would be a
-- lie against @record_audio = true@.
--
-- The ffmpeg reads from the mediamtx internal relay
-- (@rtsp://localhost:8554/<slug>@, the single-puller point from M1.B);
-- mediamtx holds the single camera pull.
--
-- The process lifetime is bracketed with 'reapProcess' (pitfall #130):
-- a supervisor cancellation lands inside the stdout read loop and would
-- otherwise skip 'waitForProcess', leaving the abandoned ffmpeg as a
-- zombie when it dies of EPIPE a moment later.
runOnce :: CaptureConfig -> CameraConfig -> IO ExitCode
runOnce cfg cam = do
  let argsConfig =
        RecordingConfig
          { rcUrl = ccRtspUrl cam,
            rcTransport = ccTransport cam,
            rcRecordAudio = ccRecordAudio cam,
            rcAudioInputRateHz = ccAudioInputRateHz cam
          }
  bracket
    ( createProcess
        (proc "ffmpeg" (recordingArgs argsConfig))
          { std_out = CreatePipe,
            std_err = Inherit
          }
    )
    (\(_, _, _, ph) -> reapProcess ph)
    $ \(_, mOut, _, ph) -> do
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
      now <- getCurrentTime
      flushPendingAt cfg cam now pending
    else do
      let (frags, st') = feed st chunk
      newPending <- foldM (handleFragment cfg cam) pending frags
      processStream cfg cam h st' newPending

-- | A previously-received media fragment held back so we can stamp its
-- @sEnd@ when the next one arrives.
data PendingFrag = PendingFrag
  { pfStart :: !UTCTime,
    pfBytes :: !ByteString,
    pfSha :: !Sha256,
    pfKey :: !Text,
    pfHasAudio :: !Bool
  }

-- | Compute sha256, push to S3 (or spool), publish 'SegmentWritten' on
-- NATS (if Bus configured). Catches per-fragment errors so one bad put
-- doesn't kill the whole stream.
--
-- For 'MediaFragment', this enqueues the fragment as the new pending and
-- (if there was already a pending) publishes that one with
-- @sEnd = current wall-clock@. Returns the updated pending state.
--
-- @pfHasAudio@ comes from the fragment's moof traf count (per-fragment
-- truth from 'Hnvr.Capture.Fmp4', not from the config flag — a camera
-- without an audio track yields video-only moofs even when
-- @record_audio@ is set).
handleFragment :: CaptureConfig -> CameraConfig -> Maybe PendingFrag -> Fragment -> IO (Maybe PendingFrag)
handleFragment cfg cam pending frag =
  case frag of
    InitFragment bs -> do
      let key = ccSlug cam <> "/init.mp4"
      for_ (ccClipBuffer cam) $ \buf ->
        atomically (modifyTVar' buf (RB.setInit bs))
      storeOrUpload cfg cam key bs "init"
      pure pending
    MediaFragment _tfdt hasAudio bs -> do
      ts <- getCurrentTime
      for_ (ccClipBuffer cam) $ \buf ->
        atomically (modifyTVar' buf (RB.push ts bs))
      let sha = sha256Bytes bs
          key = formatSegmentObjectKeyMs (ccSlug cam) ts
      -- Upload the current fragment immediately (S3 latency unchanged).
      storeOrUpload cfg cam key bs "media"
      -- Publish the previous pending (if any) now that we know its end.
      flushPendingAt cfg cam ts pending
      pure (Just (PendingFrag ts bs sha key hasAudio))
    `catch` \(e :: SomeException) -> do
      case fromException e of
        Just (SomeAsyncException _) -> throwIO e
        Nothing -> pure ()
      logErr cam $ "fragment handler failed: " <> show e
      pure pending

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
                sHasAudio = pfHasAudio p,
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
          case fromException e of
            Just (SomeAsyncException _) -> throwIO e
            Nothing -> pure ()
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
