{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.Segment".
module Hnvr.Core.SegmentSpec (tests) where

import Data.Aeson (FromJSON, ToJSON, decode, encode)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Text (Text)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), picosecondsToDiffTime, secondsToDiffTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Data.Word (Word)
import Hnvr.Core.Id (CameraId (..), HostId (..), Sha256 (..))
import Hnvr.Core.Segment
  ( Segment (..),
    SegmentKind (..),
    SegmentWritten (..),
    toSegmentWritten,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Segment"
    [ testCase "toSegmentWritten projects every field" $ do
        let seg = sampleSegment
            sw = toSegmentWritten sampleKey seg
        assertEqual "swCamera" (sCamera seg) (swCamera sw)
        assertEqual "swSlug" (sSlug seg) (swSlug sw)
        assertEqual "swStart" (sStart seg) (swStart sw)
        assertEqual "swEnd" (sEnd seg) (swEnd sw)
        assertEqual "swSha" (sSha seg) (swSha sw)
        assertEqual "swKind" (sKind seg) (swKind sw)
        assertEqual "swHostId" (sHostId seg) (swHostId sw)
        assertEqual "swBytes" (fromIntegral (B.length (sBytes seg)) :: Word) (fromIntegral (swBytes sw) :: Word),
      testCase "toSegmentWritten uses the caller-supplied object key verbatim" $ do
        let sw = toSegmentWritten sampleKey sampleSegment
        assertEqual "object key" sampleKey (swObjectKey sw),
      testCase "SegmentWritten ToJSON/FromJSON roundtrip" $ do
        let sw = toSegmentWritten sampleKey sampleSegment
            enc = encode sw
            dec = decode enc :: Maybe SegmentWritten
        assertEqual "roundtrip" (Just sw) dec
    ]

-- ---- fixtures ------------------------------------------------------

-- | Millisecond-precision key, as the capture worker computes it at
-- upload time. The envelope must carry it verbatim — recomputing at
-- second precision breaks the DB→S3 join for HEVC cameras (pitfall #25).
sampleKey :: Text
sampleKey = "cam-197/2026-08-07/12-30-45.123.mp4"

sampleSegment :: Segment
sampleSegment =
  Segment
    { sCamera = CameraId sampleUuid,
      sSlug = "cam-197",
      sStart = ts,
      sEnd = ts,
      sBytes = "fake fragment bytes",
      sSha = Sha256 (B.replicate 32 0xAB),
      sKind = Video,
      sHostId = "hnvr-2"
    }
  where
    ts = msTime 2026 8 7 12 30 45 0

-- A fixed UUID so the JSON roundtrip is stable across runs.
sampleUuid :: UUID
sampleUuid =
  case UUID.fromText "00000000-0000-0000-0000-000000000001" of
    Just u -> u
    Nothing -> error "invalid UUID literal in test fixture"

msTime :: Integer -> Int -> Int -> Int -> Int -> Int -> Int -> UTCTime
msTime year month day hour min sec ms =
  UTCTime
    (fromGregorian year month day)
    ( secondsToDiffTime (fromIntegral (hour * 3600 + min * 60 + sec))
        + picosecondsToDiffTime (fromIntegral ms * 1_000_000_000)
    )
