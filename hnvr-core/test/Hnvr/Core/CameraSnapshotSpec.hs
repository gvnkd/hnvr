{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.CameraSnapshot".
--
-- Covers the 'Transport' text/JSON codecs (the wire form that
-- @hnvr.commands.assign@ and snapshot replies carry) and JSON
-- round-trips for 'CameraSnapshot', 'RuleSnapshot' and
-- 'CameraSnapshotBatch' — leader and node must agree on these byte
-- for byte.
module Hnvr.Core.CameraSnapshotSpec (tests) where

import Data.Aeson (Value (..), decode, encode, object, (.=))
import qualified Data.Aeson.KeyMap as KM
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Hnvr.Core.CameraSnapshot
  ( CameraSnapshot (..),
    CameraSnapshotBatch (..),
    RuleSnapshot (..),
    Transport (..),
    transportFromText,
    transportToText,
  )
import Hnvr.Core.Id (CameraId (..))
import Test.QuickCheck (Arbitrary (arbitrary), Property, elements, (===))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Test.Tasty.QuickCheck (testProperty)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.CameraSnapshot"
    [ testGroup
        "transport text codec"
        [ testProperty "fromText . toText = Just" prop_transportTextRoundtrip,
          testCase "rejects unknown value" $
            transportFromText "quic" @?= Nothing,
          testCase "rejects uppercase (wire form is lowercase)" $
            transportFromText "TCP" @?= Nothing,
          testCase "wire forms are ffmpeg flag values" $ do
            transportToText TcpTransport @?= "tcp"
            transportToText UdpTransport @?= "udp"
        ],
      testGroup
        "transport JSON"
        [ testCase "encodes as bare string" $
            encode TcpTransport @?= "\"tcp\"",
          testCase "decodes udp" $
            (decode "\"udp\"" :: Maybe Transport) @?= Just UdpTransport,
          testCase "unknown value fails to decode" $
            (decode "\"srt\"" :: Maybe Transport) @?= Nothing
        ],
      testCase "RuleSnapshot JSON roundtrip" $ do
        let rs =
              RuleSnapshot
                { rsId = "5f1d0a2e-0000-0000-0000-000000000042",
                  rsKind = "line_cross",
                  rsGeometry =
                    object
                      [ "x1" .= (0 :: Int),
                        "y1" .= (0 :: Int),
                        "x2" .= (1 :: Int),
                        "y2" .= (1 :: Int)
                      ],
                  rsClasses = [0, 2],
                  rsCooldownMs = 5000,
                  rsClipPrerollSec = 5,
                  rsClipPostrollSec = 10,
                  rsClipRetentionHours = Just 168
                }
        decode (encode rs) @?= Just rs,
      testCase "CameraSnapshot JSON roundtrip" $
        decode (encode sampleSnapshot) @?= Just sampleSnapshot,
      testCase "CameraSnapshotBatch JSON roundtrip" $
        decode (encode sampleBatch) @?= Just sampleBatch,
      testCase "batch wire shape is a cameras-keyed object" $
        case decode (encode sampleBatch) of
          Just (Object o) -> assertBool "has cameras key" (KM.member "cameras" o)
          _ -> assertBool "expected top-level object" False
    ]

prop_transportTextRoundtrip :: Transport -> Property
prop_transportTextRoundtrip t = transportFromText (transportToText t) === Just t

instance Arbitrary Transport where
  arbitrary = elements [minBound .. maxBound]

-- ---- fixtures ------------------------------------------------------

sampleSnapshot :: CameraSnapshot
sampleSnapshot =
  CameraSnapshot
    { csId = CameraId sampleUuid,
      csSlug = "floor_2_5",
      csRtspUrl = "rtsp://admin:123456@192.168.0.197:554/stream=MainStream",
      csTransport = TcpTransport,
      csRecordAudio = True,
      csRtspSubUrl = Just "rtsp://admin:123456@192.168.0.197:554/stream=SubStream",
      csUseSubstream = True,
      csSubWidth = Just 720,
      csSubHeight = Just 480,
      csAnalysisFps = 5,
      csModelName = "yolov8n-320",
      csRules = [],
      csPtz = Nothing
    }

sampleBatch :: CameraSnapshotBatch
sampleBatch =
  CameraSnapshotBatch
    { csbCameras =
        [ sampleSnapshot,
          sampleSnapshot {csSlug = "backyard", csTransport = UdpTransport}
        ],
      csbClaimed = True
    }

sampleUuid :: UUID
sampleUuid =
  case UUID.fromText "00000000-0000-0000-0000-000000000001" of
    Just u -> u
    Nothing -> error "invalid UUID literal in test fixture"
