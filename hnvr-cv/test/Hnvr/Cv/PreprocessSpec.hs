{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Tests for "Hnvr.Cv.Preprocess".
--
-- Unit tests pin the Ultralytics letterbox geometry on known sizes;
-- properties cover arbitrary frame dimensions (output shape, value
-- range, aspect-ratio preservation, padding symmetry).
module Hnvr.Cv.PreprocessSpec (tests) where

import Data.Massiv.Array (Ix2 ((:.)), Ix4, IxN ((:>)), S, Sz4, size, (!), pattern Sz4)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import qualified Data.Vector.Storable as VS
import Data.Word (Word8)
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Cv.OnnxRuntime (Tensor (..))
import Hnvr.Cv.Preprocess
  ( Letterbox (..),
    letterboxGeometry,
    padValue,
    preprocess,
    preprocessTo,
    toTensor,
  )
import Test.QuickCheck (Arbitrary (arbitrary), Property, choose, forAll, vectorOf, (===))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))
import Test.Tasty.QuickCheck (testProperty)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Cv.Preprocess"
    [ testGroup
        "letterboxGeometry"
        [ testCase "320x320 into 320: no scale, no pad" $
            letterboxGeometry 320 320 320 320
              @?= Letterbox 320 320 0 0 1.0,
          testCase "640x480 into 320: 320x240 + 40px vertical pad" $ do
            let lb = letterboxGeometry 320 320 640 480
            lbScaledW lb @?= 320
            lbScaledH lb @?= 240
            lbPadX lb @?= 0
            lbPadY lb @?= 40,
          testCase "480x640 into 320: 240x320 + 40px horizontal pad" $ do
            let lb = letterboxGeometry 320 320 480 640
            lbScaledW lb @?= 240
            lbScaledH lb @?= 320
            lbPadX lb @?= 40
            lbPadY lb @?= 0
        ],
      testGroup
        "preprocess"
        [ testCase "output shape is 1x3x320x320" $ do
            let arr = preprocess (mkFrame 640 480 128)
            size arr @?= Sz4 1 3 320 320,
          testCase "pad rows carry padValue" $ do
            let arr = preprocess (mkFrame 640 480 200)
                row0 = [arr ! (0 :> c :> 0 :. x) | c <- [0 .. 2], x <- [0 .. 319]]
            mapM_ (\v -> assertBool ("pad pixel " <> show v) (abs (v - padValue) < 1e-6)) row0,
          testCase "uniform frame stays uniform in the scaled region" $ do
            let arr = preprocess (mkFrame 640 480 200)
                center = arr ! (0 :> 0 :> 160 :. 160)
            assertBool ("center " <> show center) (abs (center - 200 / 255) < 2e-3),
          testCase "toTensor flattens to [1,3,320,320]" $ do
            let t = toTensor (preprocess (mkFrame 100 50 7))
            tensorShape t @?= [1, 3, 320, 320]
            VS.length (tensorData t) @?= 3 * 320 * 320
        ],
      testGroup
        "properties"
        [ testProperty "scaled dims fit the target and keep aspect" prop_aspect,
          testProperty "one axis is unpadded" prop_oneAxisUnpadded,
          testProperty "all values in [0,1]" prop_valueRange
        ]
    ]

mkFrame :: Int -> Int -> Word8 -> Frame
mkFrame w h px =
  Frame
    { frameWidth = w,
      frameHeight = h,
      frameTimestamp = UTCTime (fromGregorian 2026 8 12) (secondsToDiffTime 0),
      frameRgb = VS.replicate (w * h * 3) px
    }

-- Scaled dims are the exact uniformly-scaled dims rounded to the
-- nearest pixel, and the limiting axis fills the target exactly.
prop_aspect :: Property
prop_aspect =
  forAll (choose (1, 1024)) $ \w ->
    forAll (choose (1, 1024)) $ \h ->
      let lb = letterboxGeometry 320 320 w h
          exactW = fromIntegral w * lbScale lb
          exactH = fromIntegral h * lbScale lb
       in abs (fromIntegral (lbScaledW lb) - exactW) <= 0.5
            && abs (fromIntegral (lbScaledH lb) - exactH) <= 0.5
            && (lbScaledW lb == 320 || lbScaledH lb == 320)

-- Letterbox pads exactly one axis (or neither for exact aspect).
prop_oneAxisUnpadded :: Property
prop_oneAxisUnpadded =
  forAll (choose (1, 1024)) $ \w ->
    forAll (choose (1, 1024)) $ \h ->
      let lb = letterboxGeometry 320 320 w h
       in lbPadX lb == 0 || lbPadY lb == 0

-- Whatever the input bytes, normalized output stays in [0,1].
prop_valueRange :: Property
prop_valueRange =
  forAll (choose (1, 64)) $ \w ->
    forAll (choose (1, 64)) $ \h ->
      forAll (vectorOf (w * h * 3) arbitrary) $ \bytes ->
        let frame =
              Frame
                { frameWidth = w,
                  frameHeight = h,
                  frameTimestamp = UTCTime (fromGregorian 2026 8 12) (secondsToDiffTime 0),
                  frameRgb = VS.fromList (bytes :: [Word8])
                }
            arr = preprocessTo 32 frame
            Sz4 _ _ th tw = size arr
            vals = [arr ! (0 :> c :> y :. x) | c <- [0 .. 2], y <- [0 .. th - 1], x <- [0 .. tw - 1]]
         in all (\v -> v >= 0 && v <= 1) vals
