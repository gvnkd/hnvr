{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Per-camera analysis pipeline glue (design_docs/04-cv-pipeline.md
-- stages 1–4):
--
-- @
-- Frame → preprocess (letterbox 320×320) → ONNX infer → decode+NMS
--       → unletterbox to source pixels → SORT update → confirmed tracks
-- @
--
-- One 'Analyzer' per camera (one ONNX session each — sessions are not
-- shared across workers, per design §"Session lifecycle"). The frame
-- source (analysis ffmpeg → TChan) and the debug-view sink are
-- separate slices; this module is the per-frame kernel.
--
-- EP selection comes from @HNVR_EXEC_PROVIDERS@ (comma-separated,
-- priority order; first provider whose session initializes wins).
module Hnvr.Cv.Analyzer
  ( AnalyzerConfig (..),
    defaultAnalyzerConfig,
    Analyzer (..),
    withAnalyzer,
    analyzeFrame,
    trackerFromEnv,
    parseExecProviders,
    execProviderName,
    execProvidersFromEnv,
  )
where

import Control.Exception (evaluate)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Cv.Decode
  ( decode,
    defaultConfThreshold,
    defaultKeepClasses,
    defaultMaxPerClass,
    defaultNmsIou,
    nms,
    unletterboxDetection,
  )
import Hnvr.Cv.OnnxRuntime
  ( ExecutionProvider (..),
    Session,
    Tensor (..),
    infer,
    sessionInputShape,
    withSession,
  )
import Hnvr.Cv.Preprocess (letterboxGeometry, preprocessTo, toTensor)
import Hnvr.Cv.Tracker.Sort (Track, Tracker, confirmedTracks)
import qualified Hnvr.Cv.Tracker.Sort as Sort
import System.Environment (lookupEnv)
import Text.Read (readMaybe)

-- | Per-camera analysis knobs. Model input size is 320 for
-- YOLOv8n-320 (YOLOv8s-640 override lands with per-camera
-- @cameras.model_name@ wiring).
data AnalyzerConfig = AnalyzerConfig
  { acConfThreshold :: !Float,
    acKeepClasses :: Int -> Bool,
    acNmsIou :: !Float,
    acMaxPerClass :: !Int,
    acTargetSize :: !Int
  }

defaultAnalyzerConfig :: AnalyzerConfig
defaultAnalyzerConfig =
  AnalyzerConfig
    { acConfThreshold = defaultConfThreshold,
      acKeepClasses = defaultKeepClasses,
      acNmsIou = defaultNmsIou,
      acMaxPerClass = defaultMaxPerClass,
      acTargetSize = 320
    }

-- | Live analyzer: session + tracker state. The tracker threads
-- through 'analyzeFrame' purely; the session is fixed for the
-- analyzer's lifetime.
data Analyzer = Analyzer
  { anSession :: Session,
    anConfig :: AnalyzerConfig,
    anTracker :: Tracker
  }

-- | Create an analyzer for @modelPath@, trying EPs in priority order.
--
-- The letterbox target follows the SESSION's input shape (e.g. 320
-- for yolov8n-320, 640 for yolov8s-640) so swapping
-- @HNVR_MODEL_PATH@ between square YOLO models needs no matching
-- config change. 'acTargetSize' is the fallback when the shape
-- doesn't look like @[1, 3, h, w]@.
withAnalyzer :: AnalyzerConfig -> Text -> [ExecutionProvider] -> (Analyzer -> IO r) -> IO r
withAnalyzer cfg modelPath eps k =
  withSession modelPath eps $ \sess -> do
    tracker <- trackerFromEnv
    let cfg' = case sessionInputShape sess of
          [1, 3, h, _w] | h > 0 -> cfg {acTargetSize = fromIntegral h}
          _ -> cfg
    k Analyzer {anSession = sess, anConfig = cfg', anTracker = tracker}

-- | Build the SORT tracker, honoring @HNVR_SORT_MAX_AGE@ (coast
-- budget in frames — how long a track survives without a detection),
-- @HNVR_SORT_MIN_HITS@ (matches before a track confirms) and
-- @HNVR_SORT_IOU_GATE@ (min IoU for a detection↔track match, 0..1).
-- Missing\/malformed values fall back to the 'Sort' defaults — a
-- typo'd knob must not kill camera start.
trackerFromEnv :: IO Tracker
trackerFromEnv = do
  maxAge <- envOr "HNVR_SORT_MAX_AGE" Sort.defaultMaxAge
  minHits <- envOr "HNVR_SORT_MIN_HITS" Sort.defaultMinHits
  iouGate <- envOr "HNVR_SORT_IOU_GATE" Sort.defaultIouGate
  pure (Sort.newTrackerWith maxAge minHits iouGate)
  where
    envOr :: (Read a) => String -> a -> IO a
    envOr name def = do
      m <- lookupEnv name
      pure $ case m of
        Just raw | Just v <- readMaybe raw -> v
        _ -> def

-- | One frame through the full pipeline. Returns the updated analyzer
-- and this frame's confirmed tracks (boxes in source-frame pixels).
analyzeFrame :: Analyzer -> Frame -> IO (Analyzer, [Track])
analyzeFrame an frame = do
  let cfg = anConfig an
      target = acTargetSize cfg
      lb = letterboxGeometry target target (frameWidth frame) (frameHeight frame)
      tensor = toTensor (preprocessTo target frame)
  out <- infer (anSession an) tensor
  let dets = decode (acConfThreshold cfg) (acKeepClasses cfg) out
      kept = nms (acNmsIou cfg) (acMaxPerClass cfg) dets
      inSource = V.map (unletterboxDetection lb) kept
      tracker' = Sort.update (anTracker an) inSource
  -- Run the SORT update NOW. 'update' is a pure lazy function; left
  -- unforced it becomes a thunk chain (one application per frame)
  -- rooted at whatever holds the tracker — and each link retains the
  -- per-frame detection pipeline (inSource → letterbox → the input
  -- 'Frame'). On zero-detection stretches nothing else forces the
  -- chain, so the analyzer leaks ~one full frame per frame (Aug 13
  -- 2026 leader OOM, ~80 MB/s at 2×15 fps 1280×720; slice-7's bake
  -- only passed because open debug streams happened to force the
  -- tracks every frame). Forcing to WHNF triggers update's internal
  -- deep force (see Sort.forceTracks), collapsing chains ≤ 1 frame.
  _ <- evaluate tracker'
  pure (an {anTracker = tracker'}, confirmedTracks tracker')

-- | Parse @HNVR_EXEC_PROVIDERS@ (comma-separated, priority order):
-- @cpu@, @cuda@, @tensorrt@ (alias @trt@). Case-insensitive, blanks
-- dropped. Unknown tokens are an error — a typo'd EP should fail loud
-- at startup, not silently fall through.
parseExecProviders :: Text -> Either Text [ExecutionProvider]
parseExecProviders input =
  let tokens = filter (not . T.null) (map T.strip (T.splitOn "," input))
   in if null tokens
        then Left "HNVR_EXEC_PROVIDERS: empty provider list"
        else mapM parseOne tokens
  where
    parseOne t = case T.toLower t of
      "cpu" -> Right CPU
      "cuda" -> Right CUDA
      "tensorrt" -> Right TensorRT
      "trt" -> Right TensorRT
      other -> Left ("HNVR_EXEC_PROVIDERS: unknown execution provider " <> other)

-- | Canonical lowercase name — the inverse of the 'parseExecProviders'
-- tokens. Used by the HealthReporter to publish the active EP list.
execProviderName :: ExecutionProvider -> Text
execProviderName = \case
  CPU -> "cpu"
  CUDA -> "cuda"
  TensorRT -> "tensorrt"

-- | Read @HNVR_EXEC_PROVIDERS@; defaults to @[CPU]@ when unset (the
-- NixOS module sets per-host defaults — @cuda,cpu@ on hnvr-1,
-- @tensorrt,cuda,cpu@ on hnvr-2). Malformed values fall back to
-- @[CPU]@ too; 'parseExecProviders' is exported for callers that want
-- the strict variant.
execProvidersFromEnv :: IO [ExecutionProvider]
execProvidersFromEnv = do
  m <- lookupEnv "HNVR_EXEC_PROVIDERS"
  case m of
    Nothing -> pure [CPU]
    Just raw ->
      case parseExecProviders (T.pack raw) of
        Right eps -> pure eps
        Left _ -> pure [CPU]
