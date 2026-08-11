{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.Assignment".
module Hnvr.Core.AssignmentSpec (tests) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import Hnvr.Core.Assignment
  ( AssignmentDecision (..),
    CameraAssignment (..),
    leastLoaded,
    pickTarget,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Assignment"
    [ testGroup
        "leastLoaded"
        [ testCase "empty map falls back to hnvr-2" $
            assertEqual "empty" "hnvr-2" (leastLoaded Map.empty),
          testCase "single-host map returns that host" $
            assertEqual
              "single"
              "hnvr-1"
              (leastLoaded (singleMap "hnvr-1")),
          testCase "picks lex-smallest of multiple hosts" $ do
            let m = singleMap "hnvr-2" <> singleMap "hnvr-1" <> singleMap "hnvr-3"
            assertEqual "lex smallest" "hnvr-1" (leastLoaded m),
          testCase "case-sensitive lexical order (uppercase first)" $ do
            -- Documents the (intentional) naive ordering: 'H' < 'h' in
            -- ASCII. Real host ids are always lowercase ('hnvr-N'), so
            -- this is a non-issue but the test pins it.
            let m = singleMap "host-A" <> singleMap "host-a"
            assertEqual "uppercase first" "host-A" (leastLoaded m)
        ],
      testGroup
        "pickTarget"
        [ testCase "manual_assign=True always keeps" $ do
            let cam = CameraAssignment "cam-1" True (Just "hnvr-99")
            -- Even if the assigned host is missing from the healthy
            -- map, manual cameras stay put.
            assertEqual
              "manual keeps"
              Keep
              (pickTarget (singleMap "hnvr-1") cam),
          testCase "current host healthy → keep (anti-flap)" $ do
            let cam = CameraAssignment "cam-1" False (Just "hnvr-1")
            assertEqual
              "keep current"
              Keep
              (pickTarget (singleMap "hnvr-1") cam),
          testCase "current host unhealthy → reassign to least-loaded" $ do
            let cam = CameraAssignment "cam-1" False (Just "hnvr-dead")
                healthy = singleMap "hnvr-1" <> singleMap "hnvr-2"
            assertEqual
              "reassign to lex-min"
              (Reassign "hnvr-1")
              (pickTarget healthy cam),
          testCase "no current host, healthy map non-empty → reassign" $ do
            let cam = CameraAssignment "cam-1" False Nothing
            assertEqual
              "first assignment"
              (Reassign "hnvr-2")
              (pickTarget (singleMap "hnvr-2") cam),
          testCase "no current host, empty healthy map → fallback hnvr-2" $ do
            -- Defensive: the coordinator short-circuits on @null hosts@,
            -- but if it didn't, leastLoaded falls back rather than crash.
            let cam = CameraAssignment "cam-1" False Nothing
            assertEqual
              "fallback"
              (Reassign "hnvr-2")
              (pickTarget Map.empty cam),
          testCase "current host already least-loaded + healthy → keep" $ do
            let cam = CameraAssignment "cam-1" False (Just "hnvr-1")
                healthy = singleMap "hnvr-1" <> singleMap "hnvr-2"
            assertEqual
              "no flap"
              Keep
              (pickTarget healthy cam)
        ]
    ]

-- ---- helpers -------------------------------------------------------

-- | Singleton healthy-host map. The value type is @UTCTime@ in
-- production (last heartbeat); tests use a fixed placeholder since
-- @pickTarget@ only inspects keys.
singleMap :: Text -> Map Text UTCTime
singleMap h = Map.singleton h t0

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 8 7) (secondsToDiffTime 0)
