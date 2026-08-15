{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.Clip" (event-clip S3 object layout) and the
-- 'ClipReady' wire envelope.
module Hnvr.Core.ClipSpec (tests) where

import Data.Aeson (decode, encode)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..))
import qualified Data.UUID
import Hnvr.Core.Clip
import Hnvr.Core.Event (ClipReady (..))
import Hnvr.Core.Id (CameraId (..), HostId (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 8 15) 3600 -- 01:00:00

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Clip"
    [ testCase "clipPrefix nests under <slug>/clips/ with trailing slash" $
        clipPrefix "backyard" t0 @?= "backyard/clips/2026-08-15/01-00-00.000/",
      testCase "clipInitKey" $
        clipInitKey "backyard/clips/2026-08-15/01-00-00.000/"
          @?= "backyard/clips/2026-08-15/01-00-00.000/init.mp4",
      testCase "clipFragKey uses ms-precision naming" $
        clipFragKey "backyard/clips/2026-08-15/01-00-00.000/" t0
          @?= "backyard/clips/2026-08-15/01-00-00.000/01-00-00.000.mp4",
      testCase "clipDurationSec floors" $
        clipDurationSec t0 (UTCTime (fromGregorian 2026 8 15) 3610.7) @?= 10,
      testCase "playlistDurations diffs consecutive keys, last falls back to 1s" $ do
        let ks@[k0, k1, k2] =
              [ "cam/clips/d/01-00-00.000.mp4",
                "cam/clips/d/01-00-01.500.mp4",
                "cam/clips/d/01-00-03.000.mp4"
              ]
        playlistDurations ks @?= [(k0, 1.5), (k1, 1.5), (k2, 1.0)],
      testCase "playlistDurations handles midnight wrap via fallback" $ do
        let ks@[k0, k1] = ["c/clips/d/23-59-59.500.mp4", "c/clips/d/00-00-00.500.mp4"]
        playlistDurations ks @?= [(k0, 1.0), (k1, 1.0)],
      testCase "playlistDurations skips unparseable keys" $
        playlistDurations ["c/clips/d/init.mp4", "c/clips/d/01-00-00.000.mp4"]
          @?= [("c/clips/d/01-00-00.000.mp4", 1.0)],
      testCase "ClipReady JSON roundtrip" $ do
        let cr =
              ClipReady
                { crCamera = CameraId nilUuid,
                  crSlug = "backyard",
                  crRuleId = Just "5f1d0a2e-0000-0000-0000-000000000042",
                  crStartedAt = t0,
                  crDurationSec = 15,
                  crObjectPrefix = "backyard/clips/2026-08-15/01-00-00.000/",
                  crRetentionHours = 168,
                  crHost = HostId "hnvr-2"
                }
        decode (encode cr) @?= Just cr
    ]
  where
    nilUuid =
      case Data.UUID.fromText "00000000-0000-0000-0000-000000000000" of
        Just u -> u
        Nothing -> error "bad uuid literal"
