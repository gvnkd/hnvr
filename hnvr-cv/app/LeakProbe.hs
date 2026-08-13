{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Leak probe: run analyzeFrame stages in isolation and watch RSS.
-- Args: stage (preprocess|infer|decode|full) frames model-path
module Main (main) where

import Control.DeepSeq (force)
import Control.Exception (evaluate)
import Control.Monad (forM_)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import qualified Data.Vector as V
import qualified Data.Vector.Storable as VS
import Data.Word (Word8)
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Cv.Analyzer
  ( Analyzer (..),
    AnalyzerConfig (..),
    analyzeFrame,
    defaultAnalyzerConfig,
    withAnalyzer,
  )
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
    Tensor (..),
    infer,
    withSession,
  )
import Hnvr.Cv.Preprocess (letterboxGeometry, preprocessTo, toTensor)
import qualified Hnvr.Cv.Tracker.Sort as Sort
import System.Environment (getArgs)
import System.IO (hPrint, stderr)
import System.Random (randomIO)

mkFrame :: Word8 -> Frame
mkFrame seed =
  Frame
    { frameWidth = 1280,
      frameHeight = 720,
      frameTimestamp = UTCTime (fromGregorian 2026 8 13) (secondsToDiffTime 0),
      frameRgb = VS.generate (1280 * 720 * 3) (\i -> fromIntegral ((i + fromIntegral seed) `mod` 251))
    }

main :: IO ()
main = do
  [stage, nStr, modelPath] <- getArgs
  let n = read nStr :: Int
  case stage of
    "preprocess" ->
      forM_ [1 .. n] $ \_ -> do
        seed <- randomIO
        let t = toTensor (preprocessTo 640 (mkFrame seed))
        _ <- evaluate (force (VS.length (tensorData t)))
        pure ()
    "infer" ->
      withSession (T.pack modelPath) [TensorRT, CUDA, CPU] $ \sess ->
        forM_ [1 .. n] $ \_ -> do
          seed <- randomIO
          out <- infer sess (toTensor (preprocessTo 640 (mkFrame seed)))
          _ <- evaluate (force (VS.length (tensorData out)))
          pure ()
    "decode" ->
      withSession (T.pack modelPath) [TensorRT, CUDA, CPU] $ \sess ->
        forM_ [1 .. n] $ \_ -> do
          seed <- randomIO
          out <- infer sess (toTensor (preprocessTo 640 (mkFrame seed)))
          let dets = decode defaultConfThreshold defaultKeepClasses out
              kept = nms defaultNmsIou defaultMaxPerClass dets
          _ <- evaluate (force (V.length kept))
          pure ()
    "full" ->
      withAnalyzer defaultAnalyzerConfig (T.pack modelPath) [TensorRT, CUDA, CPU] $ \an0 ->
        let loop _ 0 = pure ()
            loop an k = do
              seed <- randomIO
              (an', tracks) <- analyzeFrame an (mkFrame seed)
              _ <- evaluate (force (length tracks))
              loop an' (k - 1)
         in loop an0 n
    -- Mirror of the stress test / leader runner: tracks are NOT
    -- forced, just bound and discarded.
    "fulllazy" ->
      withAnalyzer defaultAnalyzerConfig (T.pack modelPath) [TensorRT, CUDA, CPU] $ \an0 ->
        let loop _ 0 = pure ()
            loop an k = do
              seed <- randomIO
              (an', _tracks) <- analyzeFrame an (mkFrame seed)
              loop an' (k - 1)
         in loop an0 n
    -- analyzeFrame's body WITHOUT confirmedTracks — isolates whether
    -- the tracks thunk or the analyzer state is the retention root.
    "notracks" ->
      withAnalyzer defaultAnalyzerConfig (T.pack modelPath) [TensorRT, CUDA, CPU] $ \an0 ->
        let loop _ 0 = pure ()
            loop an k = do
              seed <- randomIO
              let cfg = anConfig an
                  target = acTargetSize cfg
                  fr = mkFrame seed
                  lb = letterboxGeometry target target (frameWidth fr) (frameHeight fr)
                  tensor = toTensor (preprocessTo target fr)
              out <- infer (anSession an) tensor
              let dets = decode (acConfThreshold cfg) (acKeepClasses cfg) out
                  kept = nms (acNmsIou cfg) (acMaxPerClass cfg) dets
                  inSource = V.map (unletterboxDetection lb) kept
                  tracker' = Sort.update (anTracker an) inSource
              loop an {anTracker = tracker'} (k - 1)
         in loop an0 n
    _ -> hPrint stderr ("unknown stage" :: String)
