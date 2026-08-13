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
import Control.Monad (forM_, void)
import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
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
import Hnvr.Core.Frame (Frame)
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Core.Logging (logInfo, logWarn)
import Hnvr.Core.Metrics (Metrics (..))
import Hnvr.Cv.Analyzer (defaultAnalyzerConfig, execProvidersFromEnv)
import Hnvr.Cv.AnalyzerRunner (runAnalyzer)
import Hnvr.Cv.Tracker.Sort (Track)
import System.Environment (lookupEnv)
import System.Timeout (timeout)

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
-- @HNVR_ANALYSIS_ENABLED@ is not @0@. Sub-stream decode is preferred
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
      let metrics = capMetrics sup.csConfig
          (analysisCfg, width, height) = analysisConfigFor snap relayUrl
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
            (T.pack modelPath)
            eps
            queue
            (\frame tracks -> atomically (writeTVar latest (Just (frame, tracks))))
      modifyIORef' sup.csAnalysis $
        Map.insert (csId snap) AnalysisHandle {ahSource = src, ahAnalyzer = ana, ahLatest = latest}
      logInfo ("CaptureSupervisor: analysis pair started for " <> csSlug snap)

-- | Pick sub-stream decode vs main-stream-with-scale fallback per
-- camera snapshot (design 03 §2b).
analysisConfigFor :: CameraSnapshot -> Text -> (AnalysisConfig, Int, Int)
analysisConfigFor snap relayUrl =
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
            ancScale = Just (640, 360),
            ancFps = csAnalysisFps snap
          },
        640,
        360
      )

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
