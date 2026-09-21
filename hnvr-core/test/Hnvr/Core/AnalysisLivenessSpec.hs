{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.AnalysisLiveness".
module Hnvr.Core.AnalysisLivenessSpec (tests) where

import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), addUTCTime)
import Hnvr.Core.AnalysisLiveness
  ( BlindParams (..),
    BlindVerdict (..),
    RuleActivity (..),
    blindVerdict,
    defaultBlindParams,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.AnalysisLiveness"
    [ testGroup
        "blindVerdict"
        [ testCase "no activity yet is grace (BlindNoData)" $ do
            assertEqual "no data" BlindNoData (blindVerdict defaultBlindParams now Nothing),
          testCase "tracks recent + event recent is Alive" $ do
            let act = RuleActivity (ago 60) (ago 120)
            assertEqual "alive" BlindAlive (blindVerdict defaultBlindParams now (Just act)),
          testCase "tracks recent + event at window edge is Alive" $ do
            let act = RuleActivity (ago 60) (ago 7200)
            assertEqual "edge alive" BlindAlive (blindVerdict defaultBlindParams now (Just act)),
          testCase "tracks recent + event older than window is Wedged" $ do
            let act = RuleActivity (ago 60) (ago 7201)
            assertEqual "wedged" (BlindWedged "tracks active but no rule event for 7201s") (blindVerdict defaultBlindParams now (Just act)),
          testCase "tracks stale (quiet camera) is Quiet even with ancient events" $ do
            let act = RuleActivity (ago 1801) (ago 100000)
            assertEqual "quiet" BlindQuiet (blindVerdict defaultBlindParams now (Just act)),
          testCase "tracks exactly at quiet boundary still count as recent" $ do
            let act = RuleActivity (ago 1800) (ago 9000)
            assertEqual "boundary quiet" (BlindWedged "tracks active but no rule event for 9000s") (blindVerdict defaultBlindParams now (Just act)),
          testCase "custom params respected" $ do
            let params = BlindParams {bpTrackQuietSec = 60, bpEventQuietSec = 300}
                act = RuleActivity (ago 30) (ago 301)
            assertEqual "custom" (BlindWedged "tracks active but no rule event for 301s") (blindVerdict params now (Just act))
        ]
    ]
  where
    now = UTCTime (fromGregorian 2026 9 21) (12 * 3600)
    ago s = addUTCTime (negate s) now
