{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.Recording".
module Hnvr.Core.RecordingSpec (tests) where

import Data.List (sortOn)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (NominalDiffTime, UTCTime (..), addUTCTime, diffUTCTime, secondsToDiffTime)
import Hnvr.Core.Recording
  ( Gap (..),
    Recording (..),
    Span (..),
    formatRecordingDuration,
    groupRecordings,
    recBytes,
    recGaps,
    recSegmentCount,
  )
import Test.QuickCheck (Arbitrary (..), chooseInt, listOf)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)
import Test.Tasty.QuickCheck (testProperty)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Recording"
    [ testGroup
        "unit"
        [ testCase "empty input yields no recordings" $
            assertEqual "" [] (groupRecordings 30 []),
          testCase "contiguous spans form one recording" $ do
            let rs = groupRecordings 30 [mkSpan 0 5, mkSpan 5 5, mkSpan 10 5]
            assertEqual "count" 1 (length rs)
            assertEqual "segments" 3 (recSegmentCount (head rs))
            assertEqual "bytes" 300 (recBytes (head rs)),
          testCase "gap larger than tolerance splits recordings" $ do
            let rs = groupRecordings 30 [mkSpan 0 5, mkSpan 5 5, mkSpan 600 5, mkSpan 605 5]
            assertEqual "count" 2 (length rs)
            assertEqual "first run segments" 2 (recSegmentCount (head rs))
            assertEqual "second run start" (baseT 600) (recStart (rs !! 1)),
          testCase "input order does not matter" $ do
            let shuffled = [mkSpan 600 5, mkSpan 5 5, mkSpan 0 5, mkSpan 605 5]
            assertEqual "" 2 (length (groupRecordings 30 shuffled)),
          testCase "sub-tolerance hole surfaces via recGaps" $ do
            let rec = head (groupRecordings 30 [mkSpan 0 5, mkSpan 15 5, mkSpan 20 5])
            -- hole between end=5 and start=15 is 10s (> 1.5s gapMin, < 30s split)
            assertEqual "gaps" [Gap (baseT 5) (baseT 15)] (recGaps 1.5 rec),
          testCase "formatRecordingDuration renders h/m/s compactly" $ do
            let rec = head (groupRecordings 30 [mkSpan 0 (2 * 3600 + 3 * 60 + 5)])
            assertEqual "" "2h 3m 5s" (formatRecordingDuration rec)
        ],
      testGroup
        "properties"
        [ testProperty "coverage: grouping is a permutation partition" $ \(SpansInput ss) (Tol tol) ->
            concatMap recSpans (groupRecordings tol ss) == sortOn spStart ss,
          testProperty "recordings are sorted and pairwise split by > tol" $ \(SpansInput ss) (Tol tol) ->
            let rs = groupRecordings tol ss
                adjacent = zip rs (drop 1 rs)
             in all
                  ( \(a, b) ->
                      diffUTCTime (recStart b) (spEnd (last (recSpans a))) > tol
                  )
                  adjacent,
          testProperty "aggregates match members" $ \(SpansInput ss) (Tol tol) ->
            all
              ( \r ->
                  recSegmentCount r == length (recSpans r)
                    && recBytes r == sum (map spBytes (recSpans r))
                    && recStart r == spStart (head (recSpans r))
              )
              (groupRecordings tol ss)
        ]
    ]

-- ---- fixtures ------------------------------------------------------

base :: UTCTime
base = UTCTime (fromGregorian 2026 8 11) (secondsToDiffTime 0)

baseT :: Int -> UTCTime
baseT off = addUTCTime (fromIntegral off) base

-- | A segment starting @off@ seconds after 'base', lasting @dur@ seconds.
mkSpan :: Int -> Int -> Span
mkSpan off dur =
  Span
    { spStart = baseT off,
      spEnd = baseT (off + dur),
      spBytes = 100,
      spHasAudio = False,
      spObjectKey = "cam/k.mp4"
    }

-- | Generate plausible segment streams: 1s spans with realistic jitter
-- and occasional capture-restart gaps (0–90 s between runs).
newtype SpansInput = SpansInput [Span]
  deriving stock (Show)

instance Arbitrary SpansInput where
  arbitrary = do
    gaps <- listOf (chooseInt (0, 90))
    pure (SpansInput (mkSpans 0 gaps))
    where
      mkSpans _ [] = []
      mkSpans t (g : gs) =
        let s =
              Span
                { spStart = addUTCTime (fromIntegral t) base,
                  spEnd = addUTCTime (fromIntegral (t + 1)) base,
                  spBytes = 100,
                  spHasAudio = False,
                  spObjectKey = "cam/k.mp4"
                }
         in s : mkSpans (t + 1 + g) gs

-- | Split tolerances typical of the archive browser (seconds).
newtype Tol = Tol NominalDiffTime
  deriving stock (Show)

instance Arbitrary Tol where
  arbitrary = Tol . fromIntegral <$> chooseInt (1, 120)
