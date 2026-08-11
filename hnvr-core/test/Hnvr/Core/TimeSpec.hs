{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.Time".
module Hnvr.Core.TimeSpec (tests) where

import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock
  ( UTCTime (..),
    picosecondsToDiffTime,
    secondsToDiffTime,
  )
import Hnvr.Core.Time
  ( formatSegmentDir,
    formatSegmentObjectKey,
    formatSegmentObjectKeyMs,
    formatYmdHmsMs,
  )
import Test.QuickCheck (Property, (==>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)
import Test.Tasty.QuickCheck (testProperty, (===))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Time"
    [ testGroup
        "formatYmdHmsMs"
        [ testCase "zero-pads ms under 100" $ do
            -- 12:00:00.005 → ...12-00-00.005
            let t = msTime 2026 8 7 12 0 0 5
            assertEqual "ms=5" "2026-08-07/12-00-00.005" (formatYmdHmsMs t),
          testCase "zero-pads ms under 10" $ do
            let t = msTime 2026 8 7 12 0 0 9
            assertEqual "ms=9" "2026-08-07/12-00-00.009" (formatYmdHmsMs t),
          testCase "does not pad ms >= 100" $ do
            let t = msTime 2026 8 7 12 0 0 734
            assertEqual "ms=734" "2026-08-07/12-00-00.734" (formatYmdHmsMs t)
        ],
      testGroup
        "formatSegmentObjectKeyMs"
        [ testCase "appends .mp4 suffix" $ do
            let t = msTime 2026 8 7 12 0 0 0
            assertEqual
              "key"
              "cam-197/2026-08-07/12-00-00.000.mp4"
              (formatSegmentObjectKeyMs "cam-197" t),
          testProperty "is injective for ms-distinct timestamps" prop_injectiveMs
        ],
      testGroup
        "prefix relationships"
        [ testProperty "formatSegmentDir is prefix of full key" prop_dirIsPrefix
        ],
      testCase "formatSegmentObjectKey (no ms)" $ do
        let t = msTime 2026 8 7 12 0 0 0
        assertEqual
          "key"
          "cam-197/2026-08-07/12-00-00.mp4"
          (formatSegmentObjectKey "cam-197" t)
    ]

-- | Two timestamps that differ by ≥1 ms produce distinct ms-precision keys.
prop_injectiveMs :: Integer -> Integer -> Property
prop_injectiveMs msA msB =
  msA `mod` 1000 /= msB `mod` 1000 ==>
    let tA = msTime 2026 1 1 0 0 0 (fromInteger (msA `mod` 1000))
        tB = msTime 2026 1 1 0 0 0 (fromInteger (msB `mod` 1000))
     in formatSegmentObjectKeyMs "x" tA
          /= formatSegmentObjectKeyMs "x" tB

-- | @formatSegmentDir slug ts@ is a prefix of
-- @formatSegmentObjectKey slug ts <> ".mp4"@.
prop_dirIsPrefix :: Property
prop_dirIsPrefix =
  let t = msTime 2026 8 7 12 30 45 500
      dir = formatSegmentDir "cam-1" t
      key = T.unpack (formatSegmentObjectKey "cam-1" t) <> ".mp4"
   in take (T.length dir) key === T.unpack dir

-- This is a sanity check; the equality is by construction but
-- asserts the slug + date ordering is consistent across both.

-- ---- helpers -------------------------------------------------------

-- | Build a UTCTime at the given millisecond. Avoids pulling in TimeOfDay
-- formatters; just constructs the day + DiffTime directly.
msTime :: Integer -> Int -> Int -> Int -> Int -> Int -> Int -> UTCTime
msTime year month day hour min sec ms =
  UTCTime
    (fromGregorian year month day)
    ( secondsToDiffTime (fromIntegral (hour * 3600 + min * 60 + sec))
        + picosecondsToDiffTime (fromIntegral ms * 1_000_000_000)
    )
