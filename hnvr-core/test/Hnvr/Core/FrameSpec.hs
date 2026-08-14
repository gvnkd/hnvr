{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.Frame".
--
-- 'Frame' is a plain record — the meaningful invariant is the
-- @width*height*3@ byte count contract that "Hnvr.Capture.FrameSource"
-- (producer) and "Hnvr.Cv.Preprocess" (consumer) both rely on. These
-- tests pin the record shape so a future field add can't silently
-- change construction sites.
module Hnvr.Core.FrameSpec (tests) where

import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import qualified Data.Vector.Storable as VS
import Data.Word (Word8)
import Hnvr.Core.Frame (Frame (..))
import Test.QuickCheck (Positive (..), Property, (===))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Test.Tasty.QuickCheck (testProperty)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Frame"
    [ testCase "field accessors roundtrip a constructed frame" $ do
        let f = mkFrame 4 3 0xAB
        frameWidth f @?= 4
        frameHeight f @?= 3
        VS.length (frameRgb f) @?= 4 * 3 * 3
        VS.head (frameRgb f) @?= 0xAB,
      testCase "Eq distinguishes timestamps" $ do
        let f = mkFrame 2 2 0
            f' = f {frameTimestamp = laterTs}
        (f == f') @?= False,
      testProperty "replicate-built frame satisfies the byte-count contract" prop_byteCountContract
    ]

-- | The whole pipeline trusts @frameRgb == width*height*3@ bytes.
prop_byteCountContract :: Positive Int -> Positive Int -> Property
prop_byteCountContract (Positive w) (Positive h) =
  VS.length (frameRgb (mkFrame w h 0)) === w * h * 3

-- ---- fixtures ------------------------------------------------------

mkFrame :: Int -> Int -> Word8 -> Frame
mkFrame w h px =
  Frame
    { frameWidth = w,
      frameHeight = h,
      frameTimestamp = ts,
      frameRgb = VS.replicate (w * h * 3) px
    }
  where
    ts = UTCTime (fromGregorian 2026 8 14) (secondsToDiffTime 0)

laterTs :: UTCTime
laterTs = UTCTime (fromGregorian 2026 8 14) (secondsToDiffTime 1)
