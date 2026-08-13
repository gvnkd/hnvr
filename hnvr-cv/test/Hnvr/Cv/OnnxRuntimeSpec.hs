{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Smoke tests for the ONNX Runtime FFI binding.
--
-- Gated on @HNVR_ONNXRUNTIME_LIB@ (absolute path to
-- @libonnxruntime.so@) — the pinned nixpkgs @onnxruntime@ output.
-- Skips silently without it, matching the @HNVR_TEST_INTEGRATION@
-- pattern from hnvr-nats/hnvr-storage.
module Hnvr.Cv.OnnxRuntimeSpec (tests) where

import Control.Applicative ((<|>))
import Control.DeepSeq (force)
import Control.Exception (evaluate, try)
import Control.Monad (unless)
import Data.List (isPrefixOf)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import qualified Data.Vector.Storable as VS
import Data.Word (Word8)
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Cv.Analyzer (analyzeFrame, defaultAnalyzerConfig, withAnalyzer)
import Hnvr.Cv.OnnxRuntime
  ( ExecutionProvider (..),
    OrtError (..),
    Tensor (..),
    sessionActiveEp,
    versionString,
    withSession,
  )
import System.Directory (doesDirectoryExist, getTemporaryDirectory)
import System.Environment (lookupEnv, setEnv)
import System.FilePath ((</>))
import System.Random (randomIO)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Cv.OnnxRuntime"
    [ testCase "versionString reports the loaded library version" $ withLib $ do
        v <- versionString
        -- Don't pin the minor: nixpkgs bumps onnxruntime regularly
        -- (the vtable indices are what's version-locked, not this).
        assertBool ("unexpected version string: " <> v) ("1." `isPrefixOf` v),
      testCase "missing model path fails cleanly on every EP" $ withLib $ do
        r <- try (withSession "/nonexistent/model.onnx" [CUDA, TensorRT, CPU] (\_ -> pure ()))
        case r of
          Left (OrtError site msg) -> do
            assertBool ("site is withSession: " <> show site) (site == "withSession")
            mapM_
              (\ep -> assertBool ("message mentions " <> ep) (T.pack ep `T.isInfixOf` msg))
              ["CUDA", "TensorRT", "CPU"]
          Right () -> assertFailure "session creation unexpectedly succeeded",
      testCase "tensorrt session + engine cache (gated HNVR_TEST_TRT=1)" $ withLib $ do
        mTrt <- lookupEnv "HNVR_TEST_TRT"
        mModel <- (<|>) <$> lookupEnv "HNVR_TEST_MODEL" <*> lookupEnv "HNVR_MODEL_PATH"
        case (mTrt, mModel) of
          (Just "1", Just modelPath) -> do
            -- Exercises UpdateTensorRTProviderOptions (engine-cache
            -- keys) + SessionOptionsAppendExecutionProvider_TensorRT_V2
            -- + CreateSession against a TRT-enabled libonnxruntime.
            -- First run builds the engine (slow); assert the cache
            -- dir got populated so later runs are fast.
            cacheDir <- (</>) <$> getTemporaryDirectory <*> pure "hnvr-trt-cache-test"
            setEnv "HNVR_TRT_CACHE_DIR" cacheDir
            ep <- withSession (T.pack modelPath) [TensorRT] (pure . sessionActiveEp)
            unless (ep == TensorRT) $
              assertFailure ("expected TensorRT session, landed on " <> show ep)
            cached <- doesDirectoryExist cacheDir
            assertBool ("engine cache dir missing: " <> cacheDir) cached
          _ -> pure (),
      testCase "concurrent sessions stress (gated HNVR_STRESS=1)" $ withLib $ do
        mStress <- lookupEnv "HNVR_STRESS"
        mModel <- (<|>) <$> lookupEnv "HNVR_TEST_MODEL" <*> lookupEnv "HNVR_MODEL_PATH"
        case (mStress, mModel) of
          (Just "1", Just modelPath) -> do
            -- Mirror the leader's analyzer loop: fresh frame vector
            -- per iteration, massiv preprocess, allocation churn
            -- between infers. 2000 frames × 1 thread (the leader
            -- crashed with a single camera too).
            withAnalyzer defaultAnalyzerConfig (T.pack modelPath) [CPU] $ \an0 -> do
              let loop _ 0 = pure ()
                  loop an n = do
                    seed <- randomIO
                    let frame = mkStressFrame seed
                    -- churn: allocate+drop a few MB to pressure GC,
                    -- mimicking the leader's frame traffic
                    _ <- evaluate (force (VS.replicate (2 * 1024 * 1024) seed))
                    (an', _) <- analyzeFrame an frame
                    loop an' (n - 1)
              loop an0 (2000 :: Int)
          _ -> pure ()
    ]
  where
    -- Skips the test body unless HNVR_ONNXRUNTIME_LIB points at a real
    -- libonnxruntime.so; sets it so loadApi's fallback is deterministic.
    withLib :: IO () -> IO ()
    withLib body = do
      m <- lookupEnv "HNVR_ONNXRUNTIME_LIB"
      case m of
        Nothing -> pure ()
        Just p -> do
          setEnv "HNVR_ONNXRUNTIME_LIB" p
          body

-- | Fresh 640×480 frame whose bytes depend on a seed (so each
-- iteration's vector is distinct memory).
mkStressFrame :: Word8 -> Frame
mkStressFrame seed =
  Frame
    { frameWidth = 640,
      frameHeight = 480,
      frameTimestamp = UTCTime (fromGregorian 2026 8 12) (secondsToDiffTime 0),
      frameRgb = VS.generate (640 * 480 * 3) (\i -> fromIntegral ((i + fromIntegral seed) `mod` 251))
    }
