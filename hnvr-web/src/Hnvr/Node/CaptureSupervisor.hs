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

    -- * Analysis (Phase 3)
    latestAnalysis,
    analysisTVar,

    -- * Re-exports
    CaptureConfig (..),
    CameraConfig (..),
    Transport (..),
  )
where

import Control.Concurrent.Async (Async, async, cancel, waitCatch)
import Control.Concurrent.STM
  ( TVar,
    atomically,
    newTVarIO,
    readTVarIO,
    writeTVar,
  )
import Control.Exception (SomeException, try)
import Control.Monad (forM_, void)
import Data.Aeson (object, (.=))
import qualified Data.ByteString.Lazy as BL
import Data.IORef
  ( IORef,
    atomicModifyIORef',
    modifyIORef',
    newIORef,
    readIORef,
  )
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
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
    captureWorkerWithStop,
  )
import Hnvr.Core.CameraSnapshot (CameraSnapshot (..))
import qualified Hnvr.Core.CameraSnapshot as Snap
import Hnvr.Core.Event (CvEvent (..))
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Core.Geometry (Box (..))
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Core.Logging (logInfo, logWarn)
import Hnvr.Core.Metrics (Metrics (..))
import Hnvr.Core.Time (formatYmdHmsMs)
import Hnvr.Cv.Analyzer (defaultAnalyzerConfig, execProvidersFromEnv)
import Hnvr.Cv.AnalyzerRunner (runAnalyzer)
import Hnvr.Cv.DebugRender (renderDebugPng)
import Hnvr.Cv.Rules
  ( Rule,
    RuleEvent (..),
    RuleEventKind (..),
    RuleState,
    evalTracks,
    normalizeBox,
    projectRule,
  )
import Hnvr.Cv.Tracker.Sort (Track (..), TrackId (..))
import Hnvr.Nats.Bus (Bus)
import qualified Hnvr.Nats.Bus as Bus
import qualified Hnvr.Nats.Subjects as Subjects
import Hnvr.Storage.S3 (putObjectBytes)
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
    csAnalysis :: !(IORef (Map CameraId AnalysisHandle))
  }

-- | One per running camera. The @stopTVar@ is polled by the worker's
-- driver loop; setting it to 'True' causes the next state-machine tick
-- to return cleanly. The @async@ handle is waited on after stop so we
-- can reap zombie threads.
data WorkerHandle = WorkerHandle
  { whStop :: !(TVar Bool),
    whAsync :: !(Async ())
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
  -- SpoolDrainer is process-wide (not per-camera) so it can clean up
  -- after camera reassignments too. Started here so it shares the
  -- supervisor's CaptureConfig (capS3, capBucket, capSpoolDir).
  startSpoolDrainer cfg
  logInfo "CaptureSupervisor: started"
  pure (CaptureSupervisor {csConfig = cfg, csWorkers = ref, csAnalysis = aRef})

-- | Idempotent: starts a worker for the given camera. If a worker is
-- already running for the same 'CameraId', it is stopped first (so
-- updated RTSP URLs or transport take effect).
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
-- The relay port is configurable via @HNVR_MEDIAMTX_RTSP_PORT@ (default
-- 8554) so non-default deployments work. Transport is always TCP —
-- mediamtx is on localhost, no UDP needed.
startCamera :: CaptureSupervisor -> CameraSnapshot -> IO ()
startCamera sup snap = do
  stopCamera sup (csId snap)
  stopTVar <- newTVarIO False
  relayPort <- fromMaybe "8554" <$> lookupEnv "HNVR_MEDIAMTX_RTSP_PORT"
  let relayUrl = "rtsp://localhost:" <> T.pack relayPort <> "/" <> csSlug snap
      camCfg =
        CameraConfig
          { ccId = csId snap,
            ccSlug = csSlug snap,
            ccRtspUrl = relayUrl,
            ccTransport = TcpTransport,
            ccRecordAudio = csRecordAudio snap
          }
      shouldStop = readTVarIO stopTVar
  a <- async (captureWorkerWithStop sup.csConfig camCfg shouldStop)
  let handle = WorkerHandle {whStop = stopTVar, whAsync = a}
  modifyIORef' sup.csWorkers (Map.insert (csId snap) handle)
  maybeStartAnalysis sup snap relayUrl
  logInfo ("CaptureSupervisor: started worker for " <> csSlug snap <> " via " <> relayUrl)

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
      rulesRef <- newIORef (M.empty :: M.Map (Text, Int) RuleState)
      modelFile <- resolveModelPath modelPath (csModelName snap)
      let metrics = capMetrics sup.csConfig
          (analysisCfg, width, height) = analysisConfigFor fallbackScale snap relayUrl
          rules = mapMaybe projectRule (csRules snap)
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
            (analysisSink sup snap rules rulesRef latest)
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
  IORef (M.Map (Text, Int) RuleState) ->
  TVar (Maybe (Frame, [Track])) ->
  Frame ->
  [Track] ->
  IO ()
analysisSink sup snap rules rulesRef latest frame tracks = do
  atomically (writeTVar latest (Just (frame, tracks)))
  evs <-
    atomicModifyIORef' rulesRef $ \st ->
      evalTracks st rules (frameWidth frame) (frameHeight frame) tracks (frameTimestamp frame)
  case capBus sup.csConfig of
    Nothing -> pure ()
    Just bus ->
      forM_ evs $ \(rule, track, ev) -> do
        mThumb <- uploadThumbnail sup snap frame track ev
        Bus.publishJson bus Subjects.events (toCvEvent sup snap track ev frame mThumb)

-- | Draw the offending track's bbox on the frame and upload as PNG to
-- S3 (@<slug>/events/<ts>.png@). Failures degrade to 'Nothing' — the
-- event row must persist even when storage hiccups.
uploadThumbnail :: CaptureSupervisor -> CameraSnapshot -> Frame -> Track -> RuleEvent -> IO (Maybe Text)
uploadThumbnail sup snap frame track ev =
  case capS3 sup.csConfig of
    Nothing -> pure Nothing
    Just ci -> do
      let key = csSlug snap <> "/events/" <> formatYmdHmsMs (reTs ev) <> ".png"
          png = renderDebugPng frame [track]
          opts = defaultPutObjectOptions {pooContentType = Just "image/png"}
      r <-
        try
          (putObjectBytes ci (capBucket sup.csConfig) key (BL.toStrict png) opts) ::
          IO (Either SomeException ())
      case r of
        Right () -> pure (Just key)
        Left e -> do
          logWarn ("thumbnail upload failed for " <> csSlug snap <> ": " <> T.pack (show e))
          pure Nothing

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
-- worker is running for the supplied id.
stopCamera :: CaptureSupervisor -> CameraId -> IO ()
stopCamera sup camId = do
  stopAnalysisPair
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
    stopAnalysisPair = do
      mAna <-
        atomicModifyIORef'
          sup.csAnalysis
          (\m -> (Map.delete camId m, Map.lookup camId m))
      forM_ mAna $ \h -> do
        cancel h.ahSource
        cancel h.ahAnalyzer

-- | Convenience: stop + start. Useful when only config has changed
-- (e.g. RTSP URL rotation) and the caller already has the new
-- 'CameraSnapshot'.
restartCamera :: CaptureSupervisor -> CameraSnapshot -> IO ()
restartCamera sup snap = do
  stopCamera sup (csId snap)
  startCamera sup snap

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
-- (the /debug-stream middleware) block on it via STM instead of
-- polling.
analysisTVar :: CaptureSupervisor -> CameraId -> IO (Maybe (TVar (Maybe (Frame, [Track]))))
analysisTVar sup camId =
  fmap (\h -> h.ahLatest) . Map.lookup camId <$> readIORef sup.csAnalysis
