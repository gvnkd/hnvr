{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Tests for "Hnvr.Cv.AnalyzerRunner".
--
-- The runner is a live ONNX-session loop, so the suite is env-gated on
-- @HNVR_ONNXRUNTIME_LIB@ + (@HNVR_TEST_MODEL@ | @HNVR_MODEL_PATH@),
-- same as "Hnvr.Cv.OnnxRuntimeSpec". The gated test drives the real
-- loop: frames in via TBQueue, tracks out via the sink, and asserts
-- the per-frame contract (one sink call + one 'mRecordInference' per
-- frame, EP label reflecting the session's actual provider).
module Hnvr.Cv.AnalyzerRunnerSpec (tests) where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.STM (atomically, newTBQueueIO, writeTBQueue)
import Control.Monad (forM_, unless, when)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import qualified Data.Vector.Storable as VS
import Data.Word (Word8)
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Core.Metrics (Metrics (..), noOpMetrics)
import Hnvr.Cv.Analyzer (defaultAnalyzerConfig)
import Hnvr.Cv.AnalyzerRunner (runAnalyzer)
import Hnvr.Cv.OnnxRuntime (ExecutionProvider (..))
import System.Environment (lookupEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Cv.AnalyzerRunner"
    [ testCase "frame → sink loop (gated)" withModel
    ]

withModel :: IO ()
withModel = do
  mLib <- lookupEnv "HNVR_ONNXRUNTIME_LIB"
  mModel <- (<|>) <$> lookupEnv "HNVR_TEST_MODEL" <*> lookupEnv "HNVR_MODEL_PATH"
  case (mLib, mModel) of
    (Just _, Just modelPath) -> do
      q <- newTBQueueIO 4
      sinkRef <- newIORef (0 :: Int)
      inferRef <- newIORef ([] :: [(Text, Double)])
      let metrics =
            noOpMetrics
              { mRecordInference = \ep secs -> atomicModifyIORef' inferRef (\xs -> ((ep, secs) : xs, ()))
              }
          sink _frame _tracks = atomicModifyIORef' sinkRef (\n -> (n + 1, ()))
      runner <-
        async $
          runAnalyzer metrics defaultAnalyzerConfig (T.pack modelPath) [CPU] q sink
      forM_ [1 .. frameCount] $ \i -> atomically (writeTBQueue q (mkFrame (fromIntegral i)))
      waitFor sinkRef frameCount (300 :: Int) -- up to 30s
      cancel runner
      sunk <- readIORef sinkRef
      assertEqual "one sink call per frame" frameCount sunk
      infs <- readIORef inferRef
      assertEqual "one inference record per frame" frameCount (length infs)
      assertBool "EP label reflects the session provider (cpu)" (all ((== "cpu") . fst) infs)
      assertBool "inference times non-negative" (all ((>= 0) . snd) infs)
    _ -> pure ()
  where
    frameCount :: Int
    frameCount = 3

-- | Poll the ref until it reaches @target@ or the retry budget runs
-- out (100 ms per tick).
waitFor :: IORef Int -> Int -> Int -> IO ()
waitFor ref target ticks = do
  n <- readIORef ref
  unless (n >= target) $ do
    when (ticks <= 0) $ assertBool "timed out waiting for analyzer sink" False
    threadDelay 100_000
    waitFor ref target (ticks - 1)

mkFrame :: Word8 -> Frame
mkFrame seed =
  Frame
    { frameWidth = 64,
      frameHeight = 48,
      frameTimestamp = UTCTime (fromGregorian 2026 8 14) (secondsToDiffTime 0),
      frameRgb = VS.generate (64 * 48 * 3) (\i -> fromIntegral ((i + fromIntegral seed) `mod` 251))
    }
