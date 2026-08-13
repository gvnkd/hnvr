{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Tests for "Hnvr.Capture.FrameSource".
--
-- Pure slicing logic only ('sliceFrames' + 'writeDropOldest') — the
-- ffmpeg subprocess path is exercised by the live end-to-end runs on
-- Sergey's cameras, not in unit tests.
module Hnvr.Capture.FrameSourceSpec (tests) where

import Control.Concurrent.STM
import qualified Data.ByteString as B
import Data.Word (Word8)
import Hnvr.Capture.Ffmpeg (AnalysisConfig (..), Transport (..), analysisArgs)
import Hnvr.Capture.FrameSource (sliceFrames, writeDropOldest)
import Test.QuickCheck (Property, choose, forAll, vectorOf, (===))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))
import Test.Tasty.QuickCheck (testProperty)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Capture.FrameSource"
    [ testGroup
        "analysisArgs"
        [ testCase "sub-stream shape: fps only, no scale" $ do
            let args = analysisArgs subCfg
            vfOf args @?= Just "fps=5",
          testCase "fallback shape: fps + scale=640:360" $ do
            let args = analysisArgs fallbackCfg
            vfOf args @?= Just "fps=5,scale=640:360",
          testCase "outputs rgb24 rawvideo to stdout" $ do
            let args = analysisArgs subCfg
            take 2 (reverse args) @?= ["pipe:1", "rgb24"]
        ],
      testGroup
        "sliceFrames"
        [ testCase "exact multiple: all frames, empty rest" $ do
            let (frames, rest) = sliceFrames 4 (B.pack [1 .. 12])
            length frames @?= 3
            rest @?= B.empty,
          testCase "remainder carried" $ do
            let (frames, rest) = sliceFrames 4 (B.pack [1 .. 10])
            length frames @?= 2
            rest @?= B.pack [9, 10],
          testCase "short buffer: no frames, all rest" $ do
            let (frames, rest) = sliceFrames 100 (B.pack [1 .. 10])
            frames @?= []
            B.length rest @?= 10,
          testCase "every frame is exactly frameSize" $ do
            let (frames, _) = sliceFrames 7 (B.pack [1 .. 100])
            assertBool "sizes" (all ((== 7) . B.length) frames)
        ],
      testProperty "sliceFrames: concat frames <> rest == input" prop_sliceRoundTrip,
      testCase "writeDropOldest evicts head when full" $ do
        q <- newTBQueueIO 4
        atomically $ do
          mapM_ (writeTBQueue q) [1 .. 4 :: Int]
        -- queue full (bound 4); write a 5th → head evicted
        dropped <- atomically $ writeDropOldest q (5 :: Int)
        dropped @?= True
        contents <- atomically $ flushTBQueue q
        contents @?= [2, 3, 4, 5],
      testCase "writeDropOldest reports no eviction when not full" $ do
        q <- newTBQueueIO 4
        dropped <- atomically $ writeDropOldest q (1 :: Int)
        dropped @?= False
    ]
  where
    vfOf args =
      case dropWhile (/= "-vf") args of
        _flag : vf : _ -> Just vf
        _ -> Nothing

subCfg :: AnalysisConfig
subCfg =
  AnalysisConfig
    { ancUrl = "rtsp://192.168.0.197:554/sub",
      ancTransport = TcpTransport,
      ancScale = Nothing,
      ancFps = 5
    }

fallbackCfg :: AnalysisConfig
fallbackCfg =
  AnalysisConfig
    { ancUrl = "rtsp://localhost:8554/cam",
      ancTransport = TcpTransport,
      ancScale = Just (640, 360),
      ancFps = 5
    }

prop_sliceRoundTrip :: Property
prop_sliceRoundTrip =
  forAll (choose (1, 64)) $ \frameSize ->
    forAll (vectorOf 200 (choose (0, 255))) $ \bytes ->
      let buf = B.pack (bytes :: [Word8])
          (frames, rest) = sliceFrames frameSize buf
       in B.concat frames <> rest === buf
