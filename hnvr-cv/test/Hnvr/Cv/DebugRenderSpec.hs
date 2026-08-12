{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Tests for "Hnvr.Cv.DebugRender".
module Hnvr.Cv.DebugRenderSpec (tests) where

import Codec.Picture (DynamicImage (..), Image (..), PixelRGB8 (..), decodePng, pixelAt)
import qualified Data.ByteString.Lazy as BL
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import qualified Data.Vector.Storable as VS
import Data.Word (Word8)
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Core.Geometry (Box (..))
import Hnvr.Cv.DebugRender (renderDebugPng, trackColor)
import Hnvr.Cv.Tracker.Kalman (initKalman)
import Hnvr.Cv.Tracker.Sort (Track (..), TrackId (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Cv.DebugRender"
    [ testCase "trackColor is deterministic" $
        trackColor (TrackId 7) @?= trackColor (TrackId 7),
      testCase "renderDebugPng emits a PNG with the frame's dims" $ do
        let png = renderDebugPng (mkFrame 64 48 128) []
        BL.take 4 png @?= BL.pack [137, 80, 78, 71]
        case decodePng (BL.toStrict png) of
          Left err -> assertBool err False
          Right (ImageRGB8 img) -> do
            imageWidth img @?= 64
            imageHeight img @?= 48
          Right _ -> assertBool "unexpected pixel format" False,
      testCase "box outline pixels carry the track color" $ do
        let track = mkTrack 1 (Box 10 10 20 20)
            png = renderDebugPng (mkFrame 64 48 128) [track]
        case decodePng (BL.toStrict png) of
          Left err -> assertBool err False
          Right (ImageRGB8 img) -> do
            pixelAt img 10 10 @?= trackColor (TrackId 1)
            pixelAt img 29 29 @?= trackColor (TrackId 1)
            -- interior untouched
            pixelAt img 15 15 @?= PixelRGB8 128 128 128
          Right _ -> assertBool "unexpected pixel format" False,
      testCase "out-of-bounds box is clamped, not crashing" $ do
        let track = mkTrack 2 (Box (-5) (-5) 200 200)
            png = renderDebugPng (mkFrame 32 32 0) [track]
        case decodePng (BL.toStrict png) of
          Left err -> assertBool err False
          Right (ImageRGB8 img) -> pixelAt img 0 0 @?= trackColor (TrackId 2)
          Right _ -> assertBool "unexpected pixel format" False
    ]

mkFrame :: Int -> Int -> Word8 -> Frame
mkFrame w h px =
  Frame
    { frameWidth = w,
      frameHeight = h,
      frameTimestamp = UTCTime (fromGregorian 2026 8 12) (secondsToDiffTime 0),
      frameRgb = VS.replicate (w * h * 3) px
    }

mkTrack :: Int -> Box Float -> Track
mkTrack tid box =
  Track
    { tId = TrackId tid,
      tBox = box,
      tClassId = 0,
      tScore = 0.9,
      tHits = 5,
      tTimeSinceUpdate = 0,
      tAge = 5,
      tKalman = initKalman box
    }
