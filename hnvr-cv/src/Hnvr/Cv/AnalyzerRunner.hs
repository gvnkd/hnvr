-- | Analyzer worker loop: dequeue frames → 'analyzeFrame' → sink.
--
-- Thin glue between "Hnvr.Capture.FrameSource" (producer) and the
-- per-frame kernel in "Hnvr.Cv.Analyzer". One loop per camera; the
-- ONNX session is created once and reused across frame-source
-- restarts (design §"Session lifecycle" — one session per worker,
-- never shared).
--
-- The sink receives (frame, confirmed tracks) — the Phase 3 debug
-- view renders it; Phase 4's rules engine consumes the same point.
module Hnvr.Cv.AnalyzerRunner
  ( runAnalyzer,
  )
where

import Control.Concurrent.STM (TBQueue, atomically, readTBQueue)
import Data.Text (Text)
import Hnvr.Core.Frame (Frame)
import Hnvr.Cv.Analyzer
  ( Analyzer (..),
    AnalyzerConfig,
    analyzeFrame,
    withAnalyzer,
  )
import Hnvr.Cv.OnnxRuntime (ExecutionProvider)
import Hnvr.Cv.Tracker.Sort (Track)

-- | Run forever: create the analyzer, then consume frames as they
-- arrive. Cancel the enclosing async to stop.
runAnalyzer ::
  AnalyzerConfig ->
  -- | Model path (e.g. yolov8n-320.onnx).
  Text ->
  [ExecutionProvider] ->
  TBQueue Frame ->
  (Frame -> [Track] -> IO ()) ->
  IO ()
runAnalyzer cfg modelPath eps q sink =
  withAnalyzer cfg modelPath eps $ \an0 -> loop an0
  where
    loop an = do
      frame <- atomically (readTBQueue q)
      (an', tracks) <- analyzeFrame an frame
      sink frame tracks
      loop an'
