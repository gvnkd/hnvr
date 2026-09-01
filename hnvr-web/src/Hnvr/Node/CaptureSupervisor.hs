{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Per-host CaptureSupervisor.
--
-- Owns one 'CaptureWorker' async per camera currently assigned to this
-- host. The workers share a process-wide 'CaptureConfig' (NATS bus, S3
-- connection, spool dir, host id); the supervisor adds a per-worker
-- @shouldStop@ flag and an @Async ()@ handle.
--
-- Three entry points drive the supervisor:
--
--   * 'startCamera'   — idempotent insert\/replace of a worker. If the
--     camera is already running, the old worker is stopped first (so
--     updated RTSP URLs take effect on the next 'startCamera' call).
--   * 'stopCamera'    — signal stop, wait briefly for graceful exit,
--     cancel the async if it doesn't observe the flag in time.
--   * 'restartCamera' — convenience for @stopCamera >> startCamera@.
--
-- The supervisor is intentionally not crash-proof: per-worker exceptions
-- are absorbed by the underlying 'captureWorkerWithStop' driver loop
-- (it has its own backoff state machine). If a worker's async somehow
-- terminates, the next @restartCamera@ for that slug will clean up the
-- stale handle.
--
-- Phase 3 will extend this to also own AnalyzerWorker pairs (sub-stream
-- decode → CV inference). The record shape may gain fields but the API
-- ('startCamera'/'stopCamera'/'restartCamera') is stable.
module Hnvr.Node.CaptureSupervisor
  ( -- * The supervisor
    CaptureSupervisor,
    startCaptureSupervisor,

    -- * Per-camera operations
    startCamera,
    stopCamera,
    restartCamera,
    stopAllCameras,
    listCameras,

    -- * Status
    CameraStateInfo (..),
    cameraStates,

    -- * Analysis (Phase 3)
    latestAnalysis,
    analysisTVar,

    -- * Re-exports
    CaptureConfig (..),
    CameraConfig (..),
    Transport (..),
  )
where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.Async (Async, async, cancel, poll, waitCatch)
import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Control.Concurrent.STM
  ( TVar,
    atomically,
    newTVarIO,
    readTVar,
    readTVarIO,
    writeTVar,
  )
import Control.Exception
  ( SomeAsyncException (..),
    SomeException,
    finally,
    fromException,
    throwIO,
    try,
  )
import Control.Monad (forM, forM_, forever, void, when)
import Data.Aeson (object, (.=))
import qualified Data.ByteString.Lazy as BL
import Data.IORef
  ( IORef,
    atomicModifyIORef',
    modifyIORef',
    newIORef,
    readIORef,
    writeIORef,
  )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Hnvr.Capture.Ffmpeg (AnalysisConfig (..), Transport (..))
import Hnvr.Capture.FrameSource
  ( FrameSourceConfig (..),
    frameSourceLoop,
    newFrameQueue,
  )
import Hnvr.Capture.SpoolDrainer (startSpoolDrainer)
import Hnvr.Capture.Worker
  ( CameraConfig (..),
    CaptureConfig (..),
    CaptureState (..),
    captureWorkerWithStop,
  )
import Hnvr.Core.AudioProbe (ProbedAudio (..))
import Hnvr.Core.CameraSnapshot (CameraSnapshot (..), PtzSnapshot (..))
import qualified Hnvr.Core.CameraSnapshot as Snap
import Hnvr.Core.Event (CvEvent (..))
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Core.Geometry (Box (..))
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Core.Logging (logInfo, logWarn)
import Hnvr.Core.Metrics (Metrics (..))
import Hnvr.Core.Ptz (PresetToken (..))
import Hnvr.Core.Time (formatYmdHmsMs)
import Hnvr.Cv.Analyzer (defaultAnalyzerConfig, execProvidersFromEnv)
import Hnvr.Cv.AnalyzerRunner (runAnalyzer)
import Hnvr.Cv.DebugRender (renderDebugPng, renderJpeg)
import Hnvr.Cv.Rules
  ( EngineState,
    Rule,
    RuleEvent (..),
    RuleEventKind (..),
    emptyEngineState,
    evalTracks,
    normalizeBox,
    projectRule,
  )
import Hnvr.Cv.Tracker.Sort (Track (..), TrackId (..))
import Hnvr.Nats.Bus (Bus)
import qualified Hnvr.Nats.Bus as Bus
import qualified Hnvr.Nats.Subjects as Subjects
import Hnvr.Node.ClipRecorder (ClipState)
import qualified Hnvr.Node.ClipRecorder as Clip
import Hnvr.Node.SnapshotWriter (SnapshotState)
import qualified Hnvr.Node.SnapshotWriter as SnapWr
import Hnvr.Onvif.Client (OnvifCreds (..))
import Hnvr.Ptz.Controller (PtzControllerConfig (..), startPtzController)
import qualified Hnvr.Ptz.Onvif as Ptz
import Hnvr.Storage.S3 (putObjectBytes)
import Hnvr.Web.AudioProbe (probeCameraAudio)
import qualified Network.HTTP.Client as HC
import Network.Minio (defaultPutObjectOptions, pooContentType)
import qualified System.Directory as Dir
import System.Environment (lookupEnv)
import System.FilePath (takeDirectory, (<.>), (</>))
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- | Opaque handle. Construct via 'startCaptureSupervisor'.
data CaptureSupervisor = CaptureSupervisor
  { csConfig :: !CaptureConfig,
    csWorkers :: !(IORef (Map CameraId WorkerHandle)),
    csAnalysis :: !(IORef (Map CameraId AnalysisHandle)),
    -- | PTZ controllers (Phase 5): one per PTZ-enabled camera.
    csPtz :: !(IORef (Map CameraId PtzHandle)),
    -- | Per-camera lifecycle lock. Spawning a worker\/analysis pair is
    -- not atomic with inserting its handle into the maps above, so an
    -- unlocked stop-then-start racing another start (bootstrap
    -- 'startNodeRoles' vs assignLoop) could orphan a just-spawned
    -- analysis pair — unstoppable until process restart, double
    -- recording + double rule events. The lock serializes all
    -- start\/stop transitions per camera. Locks are never removed;
    -- the map stays camera-count small.
    csLocks :: !(IORef (Map CameraId (MVar ()))),
    -- | Event-clip recorder state (ring buffers + open clips).
    csClipState :: !ClipState,
    -- | Periodic snapshot writer state ('Nothing' when
    -- @HNVR_DISABLE_SNAPSHOTWRITER=1@).
    csSnapshots :: !(Maybe SnapshotState),
    -- | Throttled frame-channel publisher ('Nothing' when the bus is
    -- absent or @HNVR_FRAME_CHANNEL_FPS <= 0@). Feeds the leader's
    -- dashboard wall for remote-node cameras.
    csFramePub :: !(Maybe FramePublisher),
    -- | Probed audio input rates ('Hnvr.Web.AudioProbe') for cameras
    -- whose snapshot arrived without @csAudioInputRateHz@ (leader DB
    -- audio columns NULL — the Aug 2026 2x-slowed-archive incident).
    -- Cached per camera for the node's lifetime, successes AND
    -- failures: the probe reads the relay for ~7 s and runs under the
    -- camera's lifecycle lock.
    csAudioProbes :: !(IORef (Map CameraId (Maybe Int))),
    -- | In-flight event-thumbnail uploads. Bounded ('maxThumbInFlight')
    -- so a wedged S3 endpoint can't accumulate an unbounded pile of
    -- forked threads — pitfall #131.
    csThumbInFlight :: !(TVar Int),
    -- | Last ('CameraSnapshot', relay URL) per camera, recorded at
    -- 'startCameraLocked' and dropped at 'stopCameraLocked'. The
    -- analysis watchdog uses it to restart a dead\/wedged pair without
    -- touching the capture worker (recording must not flap because the
    -- CV side hiccuped).
    csAssignments :: !(IORef (Map CameraId (CameraSnapshot, Text)))
  }

-- | Publishes at most one JPEG per @fpMinInterval@ seconds per camera
-- on @hnvr.frames.<cameraId>@ (see 'Subjects.framesCamera').
data FramePublisher = FramePublisher
  { fpBus :: !Bus,
    fpMinInterval :: !Double,
    fpLast :: !(IORef (Map CameraId UTCTime))
  }

-- | One PTZ controller = command loop + idle ticker.
type PtzHandle = (Async (), Async ())

-- | One per running camera. The @stopTVar@ is polled by the worker's
-- driver loop; setting it to 'True' causes the next state-machine tick
-- to return cleanly. The @async@ handle is waited on after stop so we
-- can reap zombie threads. @whState@ mirrors the worker's
-- 'CaptureState' — the HealthReporter publishes it so a dead camera
-- stops showing as REC in the UI.
data WorkerHandle = WorkerHandle
  { whStop :: !(TVar Bool),
    whAsync :: !(Async ()),
    whSlug :: !Text,
    whState :: !(TVar CaptureState)
  }

-- | The Phase 3 analysis pair for one camera: frame source (analysis
-- ffmpeg → queue, self-restarting with backoff) + analyzer loop
-- (queue → ONNX → SORT). @ahLatest@ holds the most recent
-- (frame, confirmed tracks) for the /debug view.
data AnalysisHandle = AnalysisHandle
  { ahSource :: !(Async ()),
    ahAnalyzer :: !(Async ()),
    ahLatest :: !(TVar (Maybe (Frame, [Track])))
  }

-- | Construct a supervisor. The @CaptureConfig@ should carry the
-- process-wide @capBus@ \/ @capS3@ \/ @capHostId@ etc.; per-camera
-- config is supplied via 'startCamera'.
startCaptureSupervisor :: CaptureConfig -> IO CaptureSupervisor
startCaptureSupervisor cfg = do
  ref <- newIORef Map.empty
  aRef <- newIORef Map.empty
  pRef <- newIORef Map.empty
  lRef <- newIORef Map.empty
  clipState <- Clip.newClipState
  snapshots <- do
    disabled <- (== Just "1") <$> lookupEnv "HNVR_DISABLE_SNAPSHOTWRITER"
    if disabled then pure Nothing else Just <$> SnapWr.newSnapshotState
  -- SpoolDrainer is process-wide (not per-camera) so it can clean up
  -- after camera reassignments too. Started here so it shares the
  -- supervisor's CaptureConfig (capS3, capBucket, capSpoolDir).
  startSpoolDrainer cfg
  Clip.startClipTicker cfg clipState
  framePub <- do
    fps <- fromMaybe 1.0 . (>>= readMaybe) <$> lookupEnv "HNVR_FRAME_CHANNEL_FPS"
    fpRef <- newIORef Map.empty
    pure $ case (capBus cfg, fps > 0) of
      (Just bus, True) -> Just FramePublisher {fpBus = bus, fpMinInterval = 1 / fps, fpLast = fpRef}
      _ -> Nothing
  probesRef <- newIORef Map.empty
  thumbTv <- newTVarIO 0
  assignRef <- newIORef Map.empty
  let sup =
        CaptureSupervisor
          { csConfig = cfg,
            csWorkers = ref,
            csAnalysis = aRef,
            csPtz = pRef,
            csLocks = lRef,
            csClipState = clipState,
            csSnapshots = snapshots,
            csFramePub = framePub,
            csAudioProbes = probesRef,
            csThumbInFlight = thumbTv,
            csAssignments = assignRef
          }
  wdOff <- (== Just "1") <$> lookupEnv "HNVR_DISABLE_ANALYSISWATCHDOG"
  if wdOff
    then logInfo "CaptureSupervisor: analysis watchdog disabled (HNVR_DISABLE_ANALYSISWATCHDOG=1)"
    else void $ async (analysisWatchdog sup)
  logInfo "CaptureSupervisor: started"
  pure sup

-- | Fetch (or create) the per-camera lifecycle lock backing
-- 'withCameraLock'.
cameraLock :: CaptureSupervisor -> CameraId -> IO (MVar ())
cameraLock sup camId = do
  candidate <- newMVar ()
  atomicModifyIORef' sup.csLocks $ \m ->
    case Map.lookup camId m of
      Just l -> (m, l)
      Nothing -> (Map.insert camId candidate m, candidate)

-- | Run a start\/stop transition under the camera's lifecycle lock.
withCameraLock :: CaptureSupervisor -> CameraId -> IO a -> IO a
withCameraLock sup camId act = do
  l <- cameraLock sup camId
  withMVar l (const act)

-- | Idempotent: starts a worker for the given camera. If a worker is
-- already running for the same 'CameraId', it is stopped first (so
-- updated RTSP URLs or transport take effect).
--
-- Race-safe: takes the per-camera lifecycle lock and runs the whole
-- stop+start transition inside it. Concurrent callers (bootstrap
-- 'Hnvr.Web.Config.startNodeRoles' vs ConfigWatcher's assignLoop)
-- serialize instead of interleaving spawn\/insert steps — see
-- 'csLocks'.
--
-- The worker pulls from mediamtx's RTSP *server*
-- (@rtsp://localhost:8554/<slug>@) rather than from the camera
-- directly. This makes mediamtx the single ingestion point: one RTSP
-- session per camera regardless of how many internal consumers
-- (CaptureWorker + N WHEP viewers). Required for cameras with a
-- 1-concurrent-RTSP-session cap (Sergey's cam-196 and cam-198), where
-- the previous dual-pull architecture (worker + mediamtx both hitting
-- the camera) caused mediamtx's session to be torn down within ~1 s
-- of being established.
--
-- The original camera URL (carried in 'csRtspUrl') is preserved in
-- the worker's log lines for diagnostics but never reaches ffmpeg.
--
-- The relay address is configurable via @HNVR_MEDIAMTX_RTSP_HOST@
-- (default localhost — the leader's embedded mediamtx) and
-- @HNVR_MEDIAMTX_RTSP_PORT@ (default 8554) so remote worker nodes
-- pull from the leader's mediamtx instead of their own localhost.
-- Transport is always TCP — no UDP needed across the LAN relay.
startCamera :: CaptureSupervisor -> CameraSnapshot -> IO ()
startCamera sup snap =
  withCameraLock sup (csId snap) (startCameraLocked sup snap)

-- | The @asetrate@ input rate for the recording ffmpeg. The snapshot
-- value is the leader's DB truth and always wins. When it is absent
-- (leader DB @audio_sample_rate_khz@\/@audio_encoding@ NULL — every
-- recording made in that state carries 2x-slowed audio) and the
-- camera records audio, MEASURE the relay stream once with
-- "Hnvr.Web.AudioProbe" and cache the result for the node's
-- lifetime. Cameras that don't record audio never probe.
resolveAudioRate :: CaptureSupervisor -> CameraSnapshot -> Text -> IO (Maybe Int)
resolveAudioRate sup snap relayUrl
  | Just hz <- csAudioInputRateHz snap = pure (Just hz)
  | not (csRecordAudio snap) = pure Nothing
  | otherwise = do
      cached <- Map.lookup (csId snap) <$> readIORef sup.csAudioProbes
      case cached of
        Just hz -> pure hz
        Nothing -> do
          mpa <- probeCameraAudio relayUrl
          let hz = mpa >>= paAsetrateHz
          atomicModifyIORef' sup.csAudioProbes (\m -> (Map.insert (csId snap) hz m, ()))
          case hz of
            Just r ->
              logInfo
                ( "CaptureSupervisor: probed audio input rate "
                    <> T.pack (show r)
                    <> " Hz for "
                    <> csSlug snap
                )
            Nothing ->
              logWarn
                ( "CaptureSupervisor: audio rate unknown for "
                    <> csSlug snap
                    <> " — recording without asetrate retag"
                )
          pure hz

-- | Unlocked start; callers must hold the camera's lifecycle lock.
startCameraLocked :: CaptureSupervisor -> CameraSnapshot -> IO ()
startCameraLocked sup snap = do
  stopCameraLocked sup (csId snap)
  stopTVar <- newTVarIO False
  relayHost <- fromMaybe "localhost" <$> lookupEnv "HNVR_MEDIAMTX_RTSP_HOST"
  relayPort <- fromMaybe "8554" <$> lookupEnv "HNVR_MEDIAMTX_RTSP_PORT"
  -- Event-clip ring buffer: only when at least one rule on this camera
  -- has clip recording enabled (clip_retention_hours set).
  mClipBuf <-
    case Clip.bufferWindowSec (csRules snap) of
      Nothing -> pure Nothing
      Just w -> Just <$> Clip.registerBuffer sup.csClipState (csId snap) w
  let relayUrl = "rtsp://" <> T.pack relayHost <> ":" <> T.pack relayPort <> "/" <> csSlug snap
  audioRate <- resolveAudioRate sup snap relayUrl
  let camCfg =
        CameraConfig
          { ccId = csId snap,
            ccSlug = csSlug snap,
            ccRtspUrl = relayUrl,
            ccTransport = TcpTransport,
            ccRecordAudio = csRecordAudio snap,
            ccAudioInputRateHz = audioRate,
            ccClipBuffer = mClipBuf
          }
      shouldStop = readTVarIO stopTVar
  stateVar <- newTVarIO Pending
  a <- async (captureWorkerWithStop sup.csConfig camCfg shouldStop stateVar)
  let handle = WorkerHandle {whStop = stopTVar, whAsync = a, whSlug = csSlug snap, whState = stateVar}
  modifyIORef' sup.csWorkers (Map.insert (csId snap) handle)
  modifyIORef' sup.csAssignments (Map.insert (csId snap) (snap, relayUrl))
  maybeStartAnalysis sup snap relayUrl
  maybeStartPtz sup snap
  logInfo ("CaptureSupervisor: started worker for " <> csSlug snap <> " via " <> relayUrl)

-- | Spawn the PTZ controller (Phase 5) when the snapshot carries a
-- 'PtzSnapshot'. Discovery failure (camera offline, no PTZ service
-- advertised) logs and skips — the camera still records; the next
-- startCamera re-tries.
maybeStartPtz :: CaptureSupervisor -> CameraSnapshot -> IO ()
maybeStartPtz sup snap = case csPtz snap of
  Nothing -> pure ()
  Just ps -> case capBus sup.csConfig of
    Nothing -> logWarn ("CaptureSupervisor: no NATS bus; PTZ disabled for " <> csSlug snap)
    Just bus -> do
      mgr <- HC.newManager HC.defaultManagerSettings
      eDrv <-
        Ptz.resolveOnvifPtz
          mgr
          (OnvifCreds (psUsername ps) (psPassword ps))
          (psHost ps)
          (psOnvifPort ps)
          (psProfileToken ps)
      case eDrv of
        Left err -> logWarn ("CaptureSupervisor: PTZ unavailable for " <> csSlug snap <> ": " <> err)
        Right drv -> do
          h <-
            startPtzController
              PtzControllerConfig
                { pccBus = bus,
                  pccSlug = csSlug snap,
                  pccCameraId = csId snap,
                  pccDriver = drv,
                  pccHomePreset = PresetToken <$> psHomePresetToken ps,
                  pccIdleTimeoutS = psIdleTimeoutS ps,
                  pccMetrics = capMetrics sup.csConfig
                }
          modifyIORef' sup.csPtz (Map.insert (csId snap) h)
          logInfo ("CaptureSupervisor: PTZ controller started for " <> csSlug snap)

-- | Spawn the analysis pair (frame source + analyzer) for a camera.
--
-- Enabled when @HNVR_MODEL_PATH@ points at an ONNX model and
-- @HNVR_ANALYSIS_ENABLED@ is not @0@. The model file is per-camera:
-- @cameras.model_name@ is resolved by 'resolveModelPath' against
-- @HNVR_MODEL_DIR@ (default: the @HNVR_MODEL_PATH@ directory), so
-- e.g. one camera can run yolov8s-640 while the rest stay on
-- yolov8n-320. Sub-stream decode is preferred
-- (direct camera URL, native dims from Probe); when
-- @use_substream_for_analysis@ is false or dims/URL are missing we
-- fall back to the mediamtx relay main stream with @scale=640:360@
-- (design 03 §2b). EPs come from @HNVR_EXEC_PROVIDERS@.
maybeStartAnalysis :: CaptureSupervisor -> CameraSnapshot -> Text -> IO ()
maybeStartAnalysis sup snap relayUrl = do
  enabled <- (/= Just "0") <$> lookupEnv "HNVR_ANALYSIS_ENABLED"
  mModel <- lookupEnv "HNVR_MODEL_PATH"
  case (enabled, mModel) of
    (False, _) -> pure ()
    (_, Nothing) ->
      logWarn ("CaptureSupervisor: HNVR_MODEL_PATH unset; analysis disabled for " <> csSlug snap)
    (_, Just modelPath) -> do
      eps <- execProvidersFromEnv
      queue <- newFrameQueue
      latest <- newTVarIO Nothing
      fallbackScale <- readFallbackScale
      rulesRef <- newIORef emptyEngineState
      modelFile <- resolveModelPath modelPath (csModelName snap)
      let metrics = capMetrics sup.csConfig
          (analysisCfg, width, height) = analysisConfigFor fallbackScale snap relayUrl
          rules = mapMaybe projectRule (csRules snap)
          clipRules = Clip.clipCfgs (csRules snap)
          fsCfg =
            FrameSourceConfig
              { fscAnalysis = analysisCfg,
                fscWidth = width,
                fscHeight = height,
                fscTag = csSlug snap,
                fscMetrics = metrics
              }
      -- Relay+scale fallback (ancScale = Just …) means the sub-stream
      -- was unavailable/disabled — count it (design 03 §2b alarm).
      forM_ (ancScale analysisCfg) $ \_ -> mSubstreamFallback metrics (csSlug snap)
      src <- async (frameSourceLoop fsCfg queue)
      ana <-
        async $
          runAnalyzer
            metrics
            defaultAnalyzerConfig
            (T.pack modelFile)
            eps
            queue
            (analysisSink sup snap rules clipRules rulesRef latest)
      modifyIORef' sup.csAnalysis $
        Map.insert (csId snap) AnalysisHandle {ahSource = src, ahAnalyzer = ana, ahLatest = latest}
      logInfo ("CaptureSupervisor: analysis pair started for " <> csSlug snap <> " (model " <> csModelName snap <> ")")

-- | Resolve the per-camera model file. @cameras.model_name@ is a bare
-- name resolved against @HNVR_MODEL_DIR@ (or the directory of
-- @HNVR_MODEL_PATH@ when unset). Empty name → the env default. Missing
-- file → warn + env default: a typo'd model_name must not silently
-- kill the camera's whole analysis pair.
resolveModelPath :: FilePath -> Text -> IO FilePath
resolveModelPath defaultPath name
  | T.null name = pure defaultPath
  | otherwise = do
      mDir <- lookupEnv "HNVR_MODEL_DIR"
      let dir = fromMaybe (takeDirectory defaultPath) mDir
          candidate = dir </> T.unpack name <.> "onnx"
      exists <- Dir.doesFileExist candidate
      if exists
        then pure candidate
        else do
          logWarn
            ( "CaptureSupervisor: model file "
                <> T.pack candidate
                <> " not found; falling back to HNVR_MODEL_PATH"
            )
          pure defaultPath

-- | Per-frame sink: store the latest (frame, tracks) for the debug
-- view, evaluate the camera's rules, publish emitted events on
-- @hnvr.events@ (Phase 4). Rule-eval errors never escape — a bad
-- frame must not kill the analyzer loop.
analysisSink ::
  CaptureSupervisor ->
  CameraSnapshot ->
  [Rule] ->
  M.Map Text Clip.ClipCfg ->
  IORef EngineState ->
  TVar (Maybe (Frame, [Track])) ->
  Frame ->
  [Track] ->
  IO ()
analysisSink sup snap rules clipRules rulesRef latest frame tracks = do
  atomically (writeTVar latest (Just (frame, tracks)))
  forM_ sup.csFramePub $ \fp -> publishFrame fp (csId snap) frame
  forM_ sup.csSnapshots $ \st -> SnapWr.maybeSnapshot st sup.csConfig snap frame
  evs <-
    atomicModifyIORef' rulesRef $ \st ->
      evalTracks st rules (frameWidth frame) (frameHeight frame) tracks (frameTimestamp frame)
  forM_ evs $ \(_rule, _track, ev) ->
    Clip.onRuleFired sup.csClipState (csId snap) (csSlug snap) clipRules (reRuleId ev) (reTs ev)
  case capBus sup.csConfig of
    Nothing -> pure ()
    Just bus ->
      forM_ evs $ \(_rule, track, ev) -> do
        mThumb <- queueThumbnailUpload sup snap frame track ev
        Bus.publishJson bus Subjects.events (toCvEvent sup snap track ev frame mThumb)

-- | Throttled publish of a JPEG on the frame channel. Single analyzer
-- thread per camera, so the last-published map needs no lock. A NATS
-- hiccup must never kill the analyzer loop (pitfall #131) — publish
-- failures are logged and the frame dropped; the watchdog restarts the
-- pair if the analyzer dies anyway.
publishFrame :: FramePublisher -> CameraId -> Frame -> IO ()
publishFrame fp camId frame = do
  now <- getCurrentTime
  lastPub <- readIORef fp.fpLast
  let due = maybe True (\t -> realToFrac (diffUTCTime now t) >= fp.fpMinInterval) (Map.lookup camId lastPub)
  when due $ do
    writeIORef fp.fpLast (Map.insert camId now lastPub)
    r <-
      try
        ( Bus.publish
            fp.fpBus
            (Subjects.framesCamera (T.pack (show camId)))
            (BL.toStrict (renderJpeg 70 frame))
        )
    case r of
      Right () -> pure ()
      Left e
        | Just (SomeAsyncException _) <- fromException e -> throwIO e
        | otherwise ->
            logWarn ("CaptureSupervisor: frame publish failed for camera id " <> T.pack (show (unCameraId camId)) <> ": " <> T.pack (show e))

-- | Cap on concurrent forked thumbnail uploads. Beyond this, events go
-- out without a thumbnail — a missing image is a UI gap, a blocked
-- analyzer is lost detection.
maxThumbInFlight :: Int
maxThumbInFlight = 8

-- | Hard bound on one forked thumbnail upload. minio-hs retries a dead
-- endpoint forever (pitfall #108); without this the in-flight slots
-- leak during an outage and thumbnails stay disabled after recovery.
thumbUploadTimeoutUs :: Int
thumbUploadTimeoutUs = 60_000_000

-- | Draw the offending track's bbox on the frame and queue its upload
-- as PNG to S3 (@<slug>/events/<ts>.png@). The upload runs on a forked
-- thread bounded by 'thumbUploadTimeoutUs' — NEVER inline: a blocking
-- S3 call in the analyzer sink wedges rule evaluation, event
-- publishing and the @hnvr.frames@ channel for the camera until
-- process restart (pitfall #131). Returns the thumbnail key when the
-- upload was queued ('Nothing' when S3 is unconfigured or the
-- in-flight cap is hit); the event is published with that key
-- immediately, so a failed upload leaves a dangling key — acceptable
-- per the SnapshotWriter philosophy (a missing thumbnail is a UI gap,
-- not a data problem).
queueThumbnailUpload :: CaptureSupervisor -> CameraSnapshot -> Frame -> Track -> RuleEvent -> IO (Maybe Text)
queueThumbnailUpload sup snap frame track ev =
  case capS3 sup.csConfig of
    Nothing -> pure Nothing
    Just ci -> do
      let key = csSlug snap <> "/events/" <> formatYmdHmsMs (reTs ev) <> ".png"
      acquired <-
        atomically $ do
          n <- readTVar sup.csThumbInFlight
          if n >= maxThumbInFlight
            then pure False
            else do
              writeTVar sup.csThumbInFlight (n + 1)
              pure True
      if not acquired
        then do
          logWarn ("CaptureSupervisor: thumbnail upload backlog full; event for " <> csSlug snap <> " goes without thumbnail")
          pure Nothing
        else do
          void $ forkIO $ upload ci key `finally` release
          pure (Just key)
  where
    release = atomically $ do
      n <- readTVar sup.csThumbInFlight
      writeTVar sup.csThumbInFlight (n - 1)
    upload ci key = do
      let png = renderDebugPng frame [track]
          opts = defaultPutObjectOptions {pooContentType = Just "image/png"}
      r <-
        try (timeout thumbUploadTimeoutUs (putObjectBytes ci (capBucket sup.csConfig) key (BL.toStrict png) opts)) ::
          IO (Either SomeException (Maybe ()))
      case r of
        Right (Just ()) -> pure ()
        Right Nothing ->
          logWarn ("thumbnail upload timed out for " <> csSlug snap)
        Left e
          | Just (SomeAsyncException _) <- fromException e -> throwIO e
          | otherwise ->
              logWarn ("thumbnail upload failed for " <> csSlug snap <> ": " <> T.pack (show e))

-- | Project an emitted rule event + its track into the wire
-- 'CvEvent' (bbox normalized 0..1, design 06).
toCvEvent :: CaptureSupervisor -> CameraSnapshot -> Track -> RuleEvent -> Frame -> Maybe Text -> CvEvent
toCvEvent sup snap track ev frame mThumb =
  let nb = normalizeBox (frameWidth frame) (frameHeight frame) (tBox track)
      kindTxt = case reKind ev of
        LineCrossed -> "line_crossed"
        ZoneEntered -> "zone_enter"
        ZoneExited -> "zone_exit"
        ZoneInsideEvent -> "zone_inside"
        ZoneMotionEvent -> "zone_motion"
   in CvEvent
        { ceCamera = csId snap,
          ceRuleId = Just (reRuleId ev),
          ceTs = reTs ev,
          ceKind = kindTxt,
          ceClassId = Just (tClassId track),
          ceTrackId = Just (let TrackId n = tId track in n),
          ceConfidence = Just (realToFrac (tScore track)),
          ceBbox =
            Just
              ( object
                  [ "x" .= bxX nb,
                    "y" .= bxY nb,
                    "w" .= bxW nb,
                    "h" .= bxH nb
                  ]
              ),
          ceThumbnailKey = mThumb,
          ceHost = capHostId sup.csConfig
        }

-- | Pick sub-stream decode vs main-stream-with-scale fallback per
-- camera snapshot (design 03 §2b). The fallback scale comes from
-- @HNVR_ANALYSIS_SCALE@ (@1280x720@, default @640x360@) — bigger
-- frames cost decode+preprocess CPU but give the detector more
-- source pixels for small/distant objects.
analysisConfigFor :: (Int, Int) -> CameraSnapshot -> Text -> (AnalysisConfig, Int, Int)
analysisConfigFor (fbW, fbH) snap relayUrl =
  case (csUseSubstream snap, csRtspSubUrl snap, csSubWidth snap, csSubHeight snap) of
    (True, Just subUrl, Just w, Just h) ->
      ( AnalysisConfig
          { ancUrl = subUrl,
            ancTransport = TcpTransport,
            ancScale = Nothing,
            ancFps = csAnalysisFps snap
          },
        w,
        h
      )
    _ ->
      ( AnalysisConfig
          { ancUrl = relayUrl,
            ancTransport = TcpTransport,
            ancScale = Just (fbW, fbH),
            ancFps = csAnalysisFps snap
          },
        fbW,
        fbH
      )

-- | Read @HNVR_ANALYSIS_SCALE@ as @WxH@ (e.g. @1280x720@). Default
-- 640×360 (design 03 §2b). Malformed values fall back to the default
-- — a typo'd scale must not kill camera start.
readFallbackScale :: IO (Int, Int)
readFallbackScale = do
  m <- lookupEnv "HNVR_ANALYSIS_SCALE"
  pure $ case m of
    Just raw
      | (w, 'x' : hrest) <- span (/= 'x') raw,
        Just w' <- readMaybe w,
        Just h' <- readMaybe hrest ->
          (w', h')
    _ -> (640, 360)

-- | Signal stop for the worker owning this camera, wait up to 10 s for
-- a clean exit, cancel the async if it takes too long. No-op if no
-- worker is running for the supplied id. Race-safe: takes the
-- per-camera lifecycle lock (see 'csLocks').
stopCamera :: CaptureSupervisor -> CameraId -> IO ()
stopCamera sup camId = withCameraLock sup camId (stopCameraLocked sup camId)

-- | Unlocked stop; callers must hold the camera's lifecycle lock.
stopCameraLocked :: CaptureSupervisor -> CameraId -> IO ()
stopCameraLocked sup camId = do
  stopAnalysisPairLocked sup camId
  stopPtzController
  Clip.closeCameraClip sup.csConfig sup.csClipState camId
  Clip.unregisterCamera sup.csClipState camId
  modifyIORef' sup.csAssignments (Map.delete camId)
  mHandle <-
    atomicModifyIORef'
      sup.csWorkers
      (\m -> (Map.delete camId m, Map.lookup camId m))
  case mHandle of
    Nothing -> pure ()
    Just handle -> do
      atomically (writeTVar handle.whStop True)
      mEc <- timeout 10_000_000 (waitCatch handle.whAsync)
      case mEc of
        Just _ -> pure ()
        Nothing -> do
          logWarn "CaptureSupervisor: worker did not exit in 10s, cancelling"
          cancel handle.whAsync
      logInfo ("CaptureSupervisor: stopped worker for camera id " <> T.pack (show (unCameraId camId)))
  where
    stopPtzController = do
      mPtz <-
        atomicModifyIORef'
          sup.csPtz
          (\m -> (Map.delete camId m, Map.lookup camId m))
      forM_ mPtz $ \(cmdLoop, ticker) -> do
        cancel cmdLoop
        cancel ticker

-- | Remove and cancel the analysis pair for a camera. Callers must
-- hold the camera's lifecycle lock (or be the analysis watchdog,
-- which takes it itself).
stopAnalysisPairLocked :: CaptureSupervisor -> CameraId -> IO ()
stopAnalysisPairLocked sup camId = do
  mAna <-
    atomicModifyIORef'
      sup.csAnalysis
      (\m -> (Map.delete camId m, Map.lookup camId m))
  forM_ mAna $ \h -> do
    cancel h.ahSource
    cancel h.ahAnalyzer

-- | How often the analysis watchdog scans the pair table.
watchdogIntervalUs :: Int
watchdogIntervalUs = 30_000_000

-- | A pair whose newest analyzed frame is older than this while its
-- capture worker reports 'Running' is considered wedged (the pitfall
-- #131 signature: analyzer alive but stuck inside a blocking call, so
-- @hnvr.frames@, snapshots and rule events silently stop).
watchdogStaleSec :: Double
watchdogStaleSec = 120

-- | Auto-heal loop for analysis pairs (pitfall #131). Restarts a pair
-- when either async has died or the pair has stopped producing
-- analyzed frames while the camera's capture worker is 'Running'.
-- Restarts go through the per-camera lifecycle lock and re-check
-- 'csAssignments' so a concurrent 'stopCamera' can't be resurrected.
-- The capture worker is deliberately NOT touched — recording must not
-- flap because the CV side hiccuped. Kill switch:
-- @HNVR_DISABLE_ANALYSISWATCHDOG=1@.
analysisWatchdog :: CaptureSupervisor -> IO ()
analysisWatchdog sup = forever $ do
  threadDelay watchdogIntervalUs
  r <- try scan
  case r of
    Right () -> pure ()
    Left e
      | Just (SomeAsyncException _) <- fromException e -> throwIO e
      | otherwise ->
          logWarn ("CaptureSupervisor: watchdog scan failed: " <> T.pack (show e))
  where
    scan = do
      now <- getCurrentTime
      pairs <- readIORef sup.csAnalysis
      forM_ (Map.toList pairs) $ \(camId, h) -> do
        srcDead <- isDead h.ahSource
        anaDead <- isDead h.ahAnalyzer
        stale <- case srcDead || anaDead of
          True -> pure False
          False -> do
            running <- workerRunning camId
            mLatest <- readTVarIO h.ahLatest
            pure $ case mLatest of
              Just (frame, _) ->
                running && realToFrac (diffUTCTime now (frameTimestamp frame)) > watchdogStaleSec
              Nothing -> False
        when (srcDead || anaDead || stale) $ do
          let reason
                | srcDead && anaDead = "frame source + analyzer died"
                | srcDead = "frame source died"
                | anaDead = "analyzer died"
                | otherwise = "no analyzed frame for " <> T.pack (show (round watchdogStaleSec :: Int)) <> "s while Running"
          restartPair camId reason
    isDead a = do
      m <- poll a
      pure $ case m of
        Nothing -> False
        Just _ -> True
    workerRunning camId = do
      m <- readIORef sup.csWorkers
      case Map.lookup camId m of
        Nothing -> pure False
        Just wh -> (== Running) <$> readTVarIO wh.whState
    restartPair camId reason =
      withCameraLock sup camId $ do
        mAssign <- Map.lookup camId <$> readIORef sup.csAssignments
        forM_ mAssign $ \(snap, relayUrl) -> do
          logWarn ("CaptureSupervisor: restarting analysis pair for " <> csSlug snap <> " (" <> reason <> ")")
          stopAnalysisPairLocked sup camId
          maybeStartAnalysis sup snap relayUrl

-- | Convenience: stop + start under a single lock hold. Useful when
-- only config has changed (e.g. RTSP URL rotation) and the caller
-- already has the new 'CameraSnapshot'.
restartCamera :: CaptureSupervisor -> CameraSnapshot -> IO ()
restartCamera sup snap =
  withCameraLock sup (csId snap) $ do
    stopCameraLocked sup (csId snap)
    startCameraLocked sup snap

-- | Stop everything. Used on node shutdown (graceful drain before
-- process exit) and on leader-handover (the new leader will respawn
-- workers as assignments arrive).
stopAllCameras :: CaptureSupervisor -> IO ()
stopAllCameras sup = do
  cams <- listCameras sup
  forM_ cams (stopCamera sup)

-- | Snapshot of currently-running camera ids. Used by /healthz and
-- 'HealthReporter' (Phase 3 fills in the camera list payload).
listCameras :: CaptureSupervisor -> IO [CameraId]
listCameras sup = Map.keys <$> readIORef sup.csWorkers

-- | Per-camera slug + live worker state. The HealthReporter turns this
-- into the @cameras@ array of the @hnvr.health.<host>@ payload.
data CameraStateInfo = CameraStateInfo
  { csiSlug :: !Text,
    csiState :: !CaptureState
  }

cameraStates :: CaptureSupervisor -> IO [CameraStateInfo]
cameraStates sup = do
  m <- readIORef sup.csWorkers
  forM (Map.elems m) $ \h -> do
    st <- readTVarIO h.whState
    pure (CameraStateInfo h.whSlug st)

-- | Latest (frame, confirmed tracks) for a camera's analysis pair,
-- if analysis is enabled and at least one frame has been processed.
-- The Phase 3 /debug view renders this.
latestAnalysis :: CaptureSupervisor -> CameraId -> IO (Maybe (Frame, [Track]))
latestAnalysis sup camId = do
  m <- readIORef sup.csAnalysis
  case Map.lookup camId m of
    Nothing -> pure Nothing
    Just h -> readTVarIO h.ahLatest

-- | The raw 'TVar' behind 'latestAnalysis' — streaming consumers
-- (StreamDebugCameraAction) block on it via STM instead of
-- polling.
analysisTVar :: CaptureSupervisor -> CameraId -> IO (Maybe (TVar (Maybe (Frame, [Track]))))
analysisTVar sup camId =
  fmap (\h -> h.ahLatest) . Map.lookup camId <$> readIORef sup.csAnalysis
