{-# LANGUAGE OverloadedStrings #-}

module Hnvr.Core.DvripSpec (tests) where

import qualified Data.ByteString as BS
import Hnvr.Core.Dvrip
import Hnvr.Core.Onvif
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Dvrip"
    [ testGroup
        "sofiaHash (goldens from python-dvr)"
        [ testCase "123456" $ sofiaHash "123456" @?= "nTBCS19C",
          testCase "io27pJ3wui" $ sofiaHash "io27pJ3wui" @?= "JW9RtOPv",
          testCase "empty" $ sofiaHash "" @?= "tlJwpbo6"
        ],
      testGroup
        "packet framing"
        [ testCase "build/parse roundtrip" $ do
            let pkt = buildPacket 0x01020304 7 msgGetConfig "{\"a\":1}"
            BS.take 4 pkt @?= BS.pack [0xFF, 0, 0, 0],
          testCase "header fields" $ do
            let pkt = buildPacket 0x01020304 7 msgGetConfig "{\"a\":1}"
            parseHeader pkt @?= Just (0x01020304, 7, msgGetConfig, 9),
          testCase "short header rejected" $
            parseHeader (BS.pack [0xFF, 0, 0]) @?= Nothing
        ],
      testGroup
        "resolution table"
        [ testCase "6M" $ resolutionFromName "6M" @?= Just (3072, 2048),
          testCase "QVGA is 640x360 on GK7205 firmware" $ resolutionFromName "QVGA" @?= Just (640, 360),
          testCase "unknown" $ resolutionFromName "Nope" @?= Nothing,
          testCase "reverse" $ resolutionToName (704, 576) @?= Just "D1"
        ],
      testGroup
        "dvripVideoDrift"
        [ testCase "no desired → no drift" $
            dvripVideoDrift "main" emptyDesiredVideo cam198Main @?= [],
          testCase "matching → no drift" $
            dvripVideoDrift "main" desiredMatch cam198Main @?= [],
          testCase "fps + gov + res drift" $
            dvripVideoDrift "main" desiredOff cam198Main
              @?= [ DriftItem "main" "resolution" "1920x1080" "6M (3072x2048)",
                    DriftItem "main" "fps" "10" "15",
                    DriftItem "main" "govLength" "30" "15"
                  ],
          testCase "encoding drift (H264 vs H.265)" $
            dvripVideoDrift "main" (emptyDesiredVideo {dvEncoding = Just VEncH264}) cam198Main
              @?= [DriftItem "main" "encoding" "H264" "H265"]
        ],
      testGroup
        "applyDesiredVideo"
        [ testCase "sparse apply" $
            applyDesiredVideo (emptyDesiredVideo {dvFps = Just 10}) cam198Main
              @?= cam198Main {efFps = 10},
          testCase "encoding maps to dotted form" $
            efCompression (applyDesiredVideo (emptyDesiredVideo {dvEncoding = Just VEncH264}) cam198Main)
              @?= "H.264",
          testCase "resolution applies only with known name" $
            efResolution (applyDesiredVideo (emptyDesiredVideo {dvWidth = Just 1920, dvHeight = Just 1080}) cam198Main)
              @?= "1080P",
          testCase "unknown resolution keeps current" $
            efResolution (applyDesiredVideo (emptyDesiredVideo {dvWidth = Just 1234, dvHeight = Just 567}) cam198Main)
              @?= "6M",
          testCase "gov frames → seconds via fps" $
            efGop (applyDesiredVideo (emptyDesiredVideo {dvGovLength = Just 30}) cam198Main) @?= 2
        ]
    ]

cam198Main :: EncodeFormat
cam198Main = EncodeFormat True True "H.265" "6M" 15 4698 1 "VBR" 6 1

desiredMatch :: DesiredVideo
desiredMatch = DesiredVideo (Just VEncH265) (Just 3072) (Just 2048) (Just 15) (Just 4698) (Just 15)

desiredOff :: DesiredVideo
desiredOff = DesiredVideo Nothing (Just 1920) (Just 1080) (Just 10) Nothing (Just 30)
