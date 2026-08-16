{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Tests for "Hnvr.Cv.Analyzer".
--
-- Pure unit tests for the EP parser; an end-to-end pipeline test
-- (frame → tracks) gated on @HNVR_ONNXRUNTIME_LIB@ +
-- @HNVR_TEST_MODEL@ pointing at a YOLOv8-format model
-- (output @[1, 84, anchors]@). The gated test also prints the
-- probed input/output shapes to stderr — point HNVR_TEST_MODEL at any
-- .onnx file to introspect it.
module Hnvr.Cv.AnalyzerSpec (tests) where

import Control.Applicative ((<|>))
import qualified Data.ByteString as B
import qualified Data.IntMap as IM
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import qualified Data.Vector.Storable as VS
import Data.Word (Word8)
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Cv.Analyzer
  ( Analyzer (..),
    AnalyzerConfig (..),
    analyzeFrame,
    defaultAnalyzerConfig,
    execProviderName,
    execProvidersFromEnv,
    parseExecProviders,
    withAnalyzer,
  )
import Hnvr.Cv.OnnxRuntime
  ( ExecutionProvider (..),
    sessionInputShape,
    sessionOutputShape,
  )
import Hnvr.Cv.Tracker.Sort (Track (..), Tracker (..))
import System.Environment (lookupEnv, setEnv, unsetEnv)
import System.IO (hPutStrLn, stderr)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Cv.Analyzer"
    [ testGroup
        "parseExecProviders"
        [ testCase "priority order preserved" $
            parseExecProviders "tensorrt,cuda,cpu" @?= Right [TensorRT, CUDA, CPU],
          testCase "whitespace + case tolerated" $
            parseExecProviders " Cuda , CPU " @?= Right [CUDA, CPU],
          testCase "trt alias" $
            parseExecProviders "trt,cpu" @?= Right [TensorRT, CPU],
          testCase "unknown provider is an error" $
            parseExecProviders "openvino" @?= Left "HNVR_EXEC_PROVIDERS: unknown execution provider openvino",
          testCase "empty is an error" $
            parseExecProviders "" @?= Left "HNVR_EXEC_PROVIDERS: empty provider list",
          testCase "trailing comma tolerated" $
            parseExecProviders "cuda," @?= Right [CUDA]
        ],
      testGroup
        "execProviderName"
        [ testCase "canonical names" $ do
            execProviderName CPU @?= "cpu"
            execProviderName CUDA @?= "cuda"
            execProviderName TensorRT @?= "tensorrt",
          testCase "round-trips through parseExecProviders" $ do
            let eps = [TensorRT, CUDA, CPU]
            parseExecProviders (T.intercalate "," (map execProviderName eps)) @?= Right eps
        ],
      testCase "execProvidersFromEnv defaults to [CPU]" $ do
        unsetEnv "HNVR_EXEC_PROVIDERS"
        eps <- execProvidersFromEnv
        eps @?= [CPU],
      testCase "execProvidersFromEnv falls back to [CPU] on garbage" $ do
        setEnv "HNVR_EXEC_PROVIDERS" "not-a-provider"
        eps <- execProvidersFromEnv
        eps @?= [CPU]
        unsetEnv "HNVR_EXEC_PROVIDERS",
      testCase "pipeline end-to-end (gated)" withModel
    ]

-- Runs only when HNVR_ONNXRUNTIME_LIB + HNVR_TEST_MODEL are set.
-- Prints probed shapes to stderr; runs a full analyzeFrame when the
-- model is YOLOv8-format.
withModel :: IO ()
withModel = do
  mLib <- lookupEnv "HNVR_ONNXRUNTIME_LIB"
  -- HNVR_TEST_MODEL overrides; HNVR_MODEL_PATH (devenv's runtime
  -- var) is the fallback so `cabal test` exercises the real pipeline
  -- inside nix develop without extra exports.
  mModel <- (<|>) <$> lookupEnv "HNVR_TEST_MODEL" <*> lookupEnv "HNVR_MODEL_PATH"
  case (mLib, mModel) of
    (Just _, Just modelPath) ->
      withAnalyzer defaultAnalyzerConfig (T.pack modelPath) [CPU] $ \an -> do
        let inShape = sessionInputShape (anSession an)
            outShape = sessionOutputShape (anSession an)
        hPutStrLn stderr $
          "HNVR_TEST_MODEL probe: input=" <> show inShape <> " output=" <> show outShape
        case (inShape, outShape) of
          ([1, 3, s, s'], [1, 84, _]) | s == s' -> do
            let frame = mkFrame 640 480 128
            (an1, _) <- analyzeFrame an frame
            hPutStrLn stderr "uniform frame: OK"
            -- Optional real-frame probe: HNVR_TEST_FRAME="path:WxH"
            -- (raw RGB24, e.g. ffmpeg -pix_fmt rgb24 -f rawvideo).
            mFrame <- lookupEnv "HNVR_TEST_FRAME"
            case mFrame >>= parseFrameSpec of
              Nothing ->
                whenJust mFrame (\_ -> hPutStrLn stderr "HNVR_TEST_FRAME: expected path:WxH")
              Just (path, wInt, hInt) -> do
                bytes <- B.readFile path
                let real =
                      Frame
                        { frameWidth = wInt,
                          frameHeight = hInt,
                          frameTimestamp = UTCTime (fromGregorian 2026 8 12) (secondsToDiffTime 0),
                          frameRgb = VS.generate (B.length bytes) (B.index bytes)
                        }
                -- Same frame 3× so tracks confirm (minHits=3).
                (_, tracks) <-
                  iterate (\acc -> acc >>= \(a, _) -> analyzeFrame a real) (pure (an1, []))
                    !! 3
                hPutStrLn stderr $
                  "real frame: "
                    <> show (length tracks)
                    <> " confirmed tracks: "
                    <> show [(tId t, tScore t, tClassId t) | t <- take 5 tracks]
                -- Low-threshold diagnostic: are there ANY detections?
                (anLo, _) <-
                  analyzeFrame
                    an1 {anConfig = (anConfig an1) {acConfThreshold = 0.05}}
                    real
                let allT = IM.elems (trTracks (anTracker anLo))
                hPutStrLn stderr $
                  "conf=0.05: "
                    <> show (length allT)
                    <> " raw detections: "
                    <> show [(tScore t, tClassId t, tBox t) | t <- take 5 allT]
          _ -> pure ()
    _ -> pure ()

-- | Parse @HNVR_TEST_FRAME@ of the form @path:WxH@.
parseFrameSpec :: String -> Maybe (FilePath, Int, Int)
parseFrameSpec spec =
  case break (== ':') spec of
    (path, ':' : dims) ->
      case break (== 'x') dims of
        (w, 'x' : h) -> case (reads w, reads h) of
          ([(wInt, "")], [(hInt, "")]) -> Just (path, wInt, hInt)
          _ -> Nothing
        _ -> Nothing
    _ -> Nothing

whenJust :: Maybe a -> (a -> IO ()) -> IO ()
whenJust m f = maybe (pure ()) f m

mkFrame :: Int -> Int -> Word8 -> Frame
mkFrame w h px =
  Frame
    { frameWidth = w,
      frameHeight = h,
      frameTimestamp = UTCTime (fromGregorian 2026 8 12) (secondsToDiffTime 0),
      frameRgb = VS.replicate (w * h * 3) px
    }
