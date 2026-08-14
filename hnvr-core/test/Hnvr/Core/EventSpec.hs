{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.Event".
--
-- 'CvEvent' is the Phase 4 wire type published on @hnvr.events@; the
-- leader's EventWriter decodes it into the @events@ table. These tests
-- pin the JSON contract so leader and analyzer hosts can't drift.
module Hnvr.Core.EventSpec (tests) where

import Data.Aeson (decode, encode, object, (.=))
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import qualified Data.UUID as UUID
import Hnvr.Core.Event (CvEvent (..))
import Hnvr.Core.Id (CameraId (..), HostId (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Event"
    [ testCase "CvEvent JSON roundtrip (fully populated)" $
        decode (encode sampleEvent) @?= Just sampleEvent,
      testCase "CvEvent JSON roundtrip (minimal — all Maybe fields Nothing)" $
        decode (encode minimalEvent) @?= Just minimalEvent
    ]

-- ---- fixtures ------------------------------------------------------

sampleEvent :: CvEvent
sampleEvent =
  CvEvent
    { ceCamera = CameraId sampleUuid,
      ceRuleId = Just "5f1d0a2e-0000-0000-0000-000000000042",
      ceTs = ts,
      ceKind = "line_crossed",
      ceClassId = Just 0,
      ceTrackId = Just 7,
      ceConfidence = Just 0.83,
      ceBbox = Just (object ["x" .= (0.1 :: Double), "y" .= (0.2 :: Double), "w" .= (0.3 :: Double), "h" .= (0.4 :: Double)]),
      ceThumbnailKey = Just "floor_2_5/events/2026-08-14/12-30-45.123.png",
      ceHost = HostId "hnvr-2"
    }

-- | Track-lifecycle events (Phase 4b) have no rule id; S3 hiccups
-- leave no thumbnail key. Both must still decode.
minimalEvent :: CvEvent
minimalEvent =
  CvEvent
    { ceCamera = CameraId sampleUuid,
      ceRuleId = Nothing,
      ceTs = ts,
      ceKind = "zone_inside",
      ceClassId = Nothing,
      ceTrackId = Nothing,
      ceConfidence = Nothing,
      ceBbox = Nothing,
      ceThumbnailKey = Nothing,
      ceHost = HostId "hnvr-1"
    }

ts :: UTCTime
ts = UTCTime (fromGregorian 2026 8 14) (secondsToDiffTime (12 * 3600 + 30 * 60 + 45))

sampleUuid :: UUID.UUID
sampleUuid =
  case UUID.fromText "00000000-0000-0000-0000-000000000001" of
    Just u -> u
    Nothing -> error "invalid UUID literal in test fixture"
