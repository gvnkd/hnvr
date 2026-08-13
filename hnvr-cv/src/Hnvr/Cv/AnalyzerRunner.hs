{-# LANGUAGE OverloadedStrings #-}

-- | Analyzer worker loop: dequeue frames → 'analyzeFrame' → sink.--
-- Thin glue between "Hnvr.Capture.FrameSource" (producer) and the
-- per-frame kernel in "Hnvr.Cv.Analyzer". One loop per camera; the
-- ONNX session is created once and reused across frame-source
-- restarts (design §"Session lifecycle" — one session per worker,
-- never shared).
--
-- The sink receives (frame, confirmed tracks) — the Phase 3 debug
-- view renders it; Phase 4's rules engine consumes the same point.
--
-- Every frame is timed and recorded via 'mRecordInference' under the
-- EP the session actually landed on (post-fallback), so
-- @hnvr_inference_seconds{ep="…"}@ reflects reality, not the env
-- request list.
module Hnvr.Cv.AnalyzerRunner
  ( runAnalyzer,
  )
where

import Control.Concurrent.STM (TBQueue, atomically, readTBQueue)
import Data.Text (Text)
import GHC.Clock (getMonotonicTimeNSec)
import Hnvr.Core.Frame (Frame)
import Hnvr.Core.Metrics (Metrics (..))
import Hnvr.Cv.Analyzer
  ( Analyzer (..),
    AnalyzerConfig,
    analyzeFrame,
    withAnalyzer,
  )
import Hnvr.Cv.OnnxRuntime (ExecutionProvider (..), sessionActiveEp)
import Hnvr.Cv.Tracker.Sort (Track)

-- | Run forever: create the analyzer, then consume frames as they
-- arrive. Cancel the enclosing async to stop.
runAnalyzer ::
  Metrics ->
  AnalyzerConfig ->
  -- | Model path (e.g. yolov8n-320.onnx).
  Text ->
  [ExecutionProvider] ->
  TBQueue Frame ->
  (Frame -> [Track] -> IO ()) ->
  IO ()
runAnalyzer metrics cfg modelPath eps q sink =
  withAnalyzer cfg modelPath eps $ \an0 -> loop (epLabel (sessionActiveEp (anSession an0))) an0
  where
    loop ep an = do
      frame <- atomically (readTBQueue q)
      t0 <- getMonotonicTimeNSec
      (an', tracks) <- analyzeFrame an frame
      t1 <- getMonotonicTimeNSec
      mRecordInference metrics ep (fromIntegral (t1 - t0) / 1e9)
      sink frame tracks
      loop ep an'

    epLabel CPU = "cpu"
    epLabel CUDA = "cuda"
    epLabel TensorRT = "tensorrt"
