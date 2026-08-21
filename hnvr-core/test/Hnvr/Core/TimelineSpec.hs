{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.Timeline" — the pure merging/bucketing rules
-- behind @\/TimelineData@ (design_docs/12-timeline-archive.md).
module Hnvr.Core.TimelineSpec (tests) where

import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (NominalDiffTime, UTCTime (..), addUTCTime, secondsToDiffTime)
import qualified Data.UUID as UUID
import Hnvr.Core.Recording (Span (..))
import Hnvr.Core.Timeline
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Timeline"
    [ testGroup
        "coverageSpans"
        [ testCase "empty input" $
            coverageSpans 30 [] @?= [],
          testCase "adjacent segments within tolerance merge" $
            coverageSpans 30 [seg camA 0 10, seg camA 15 40, seg camA 40 50]
              @?= [CoverageSpan (t 0) (t 50)],
          testCase "gap beyond tolerance splits" $
            coverageSpans 30 [seg camA 0 10, seg camA 100 110]
              @?= [CoverageSpan (t 0) (t 10), CoverageSpan (t 100) (t 110)],
          testCase "mixed cameras do not cross-merge" $
            coverageSpans 30 [seg camA 0 10, seg camB 5 15]
              @?= [CoverageSpan (t 0) (t 10), CoverageSpan (t 5) (t 15)]
        ],
      testGroup
        "bucketMarkers"
        [ testCase "under cap passes through untruncated" $ do
            let ms = [marker (t s) | s <- [0, 60 .. 600]]
            bucketMarkers 500 (t 0) (t 3600) ms @?= (ms, False),
          testCase "exactly at cap passes through" $ do
            let ms = [marker (t s) | s <- [0, 10 .. 4990]]
            length ms @?= 500
            bucketMarkers 500 (t 0) (t 3600) ms @?= (ms, False),
          testCase "over cap keeps earliest per bucket + flags truncated" $ do
            -- 1000 markers, 2 s apart: pairs share a bucket at cap 500
            -- over a 2000 s window (bucket = 0.5 s wide... 4 s/bucket).
            let ms = [marker (t s) | s <- [0, 2 .. 1998]]
                (kept, truncated) = bucketMarkers 500 (t 0) (t 2000) ms
            truncated @?= True
            length kept @?= 500
            -- earliest of each 2-marker bucket: even-offset markers
            kept @?= [marker (t s) | s <- [0, 4 .. 1996]],
          testCase "clustered markers spread across the window" $ do
            -- 999 markers in the first minute + 1 at the end: the tail
            -- marker must survive bucketing (naive `take` would drop it).
            let ms = [marker (t s) | s <- [0, 1 .. 998]] ++ [marker (t 3500)]
                (kept, truncated) = bucketMarkers 500 (t 0) (t 3600) ms
            truncated @?= True
            last kept @?= marker (t 3500)
        ]
    ]

-- ---- fixtures ------------------------------------------------------

t :: NominalDiffTime -> UTCTime
t s = addUTCTime s t0
  where
    t0 = UTCTime (fromGregorian 2026 8 20) (secondsToDiffTime 0)

seg :: UUID.UUID -> NominalDiffTime -> NominalDiffTime -> Span
seg cid start end =
  Span
    { spCameraId = cid,
      spStart = t start,
      spEnd = t end,
      spBytes = 1000,
      spHasAudio = False,
      spObjectKey = "k",
      spHostId = Nothing,
      spSha256 = "deadbeef"
    }

marker :: UTCTime -> TimelineMarker
marker ts =
  TimelineMarker
    { tmId = nil,
      tmTs = ts,
      tmKind = "zone_motion",
      tmRule = Just "r",
      tmClipId = Nothing
    }

camA, camB, nil :: UUID.UUID
(camA, camB, nil) =
  ( u "00000000-0000-0000-0000-00000000000a",
    u "00000000-0000-0000-0000-00000000000b",
    u "00000000-0000-0000-0000-000000000000"
  )
  where
    u txt = case UUID.fromText txt of
      Just x -> x
      Nothing -> error "invalid UUID literal in test fixture"
