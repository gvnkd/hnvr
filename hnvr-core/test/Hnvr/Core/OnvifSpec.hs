{-# LANGUAGE OverloadedStrings #-}

module Hnvr.Core.OnvifSpec (tests) where

import Hnvr.Core.Onvif
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Onvif"
    [ testGroup
        "normalize"
        [ testCase "bitrate bps → kbps (Hikvision 64000)" $
            normalizeBitrateKbps 64000 @?= 64,
          testCase "bitrate kbps passes through (XM 128)" $
            normalizeBitrateKbps 128 @?= 128,
          testCase "sample rate Hz → kHz (16000)" $
            normalizeSampleRateKhz 16000 @?= 16,
          testCase "sample rate kHz passes through (8)" $
            normalizeSampleRateKhz 8 @?= 8
        ],
      testGroup
        "audioDrift"
        [ testCase "no desired → no drift" $
            audioDrift emptyDesiredAudio cam196Audio @?= [],
          testCase "matching desired → no drift" $
            audioDrift (DesiredAudio (Just EncG711) (Just 64) (Just 16)) cam196Audio @?= [],
          testCase "encoding mismatch drifts" $
            audioDrift (DesiredAudio (Just EncAAC) Nothing Nothing) cam196Audio
              @?= [DriftItem "AudioMain" "encoding" "AAC" "G711"],
          testCase "all fields mismatch" $
            audioDrift (DesiredAudio (Just EncAAC) (Just 32) (Just 8)) cam196Audio
              @?= [ DriftItem "AudioMain" "encoding" "AAC" "G711",
                    DriftItem "AudioMain" "bitrateKbps" "32" "64",
                    DriftItem "AudioMain" "sampleRateKhz" "8" "16"
                  ]
        ],
      testGroup
        "videoDrift"
        [ testCase "fps + gov mismatch" $
            videoDrift (emptyDesiredVideo {dvFps = Just 10, dvGovLength = Just 30}) cam198Video
              @?= [ DriftItem "V_ENC_000" "fps" "10" "15",
                    DriftItem "V_ENC_000" "govLength" "30" "15"
                  ],
          testCase "exact match → no drift" $
            videoDrift
              ( DesiredVideo
                  (Just VEncH264)
                  (Just 3072)
                  (Just 2048)
                  (Just 15)
                  (Just 4698)
                  (Just 15)
              )
              cam198Video
              @?= []
        ],
      testGroup
        "clampAudio"
        [ testCase "unconstrained options pass desired through" $
            clampAudio (AudioOptions [] [] []) cam196Audio (DesiredAudio (Just EncAAC) (Just 32) (Just 8))
              @?= cam196Audio {acEncoding = EncAAC, acBitrateKbps = 32, acSampleRateKhz = 8},
          testCase "unsupported encoding falls back to current" $
            clampAudio (AudioOptions [EncG711] [128] [8]) cam198Audio (DesiredAudio (Just EncAAC) Nothing Nothing)
              @?= cam198Audio,
          testCase "off-list bitrate snaps to nearest offered" $
            clampAudio (AudioOptions [] [32, 64, 128] []) cam196Audio (DesiredAudio Nothing (Just 100) Nothing)
              @?= cam196Audio {acBitrateKbps = 128}
        ],
      testGroup
        "clampVideo"
        [ testCase "resolution snaps to nearest offered" $
            let opts = VideoOptions [] [(1920, 1080), (3072, 2048)] Nothing Nothing Nothing
             in clampVideo opts cam198Video (emptyDesiredVideo {dvWidth = Just 3000, dvHeight = Just 2000})
                  @?= cam198Video,
          testCase "fps clamps into range" $
            let opts = VideoOptions [] [] (Just (1, 10)) Nothing Nothing
             in vcFps (clampVideo opts cam198Video (emptyDesiredVideo {dvFps = Just 15})) @?= 10,
          testCase "unmanaged fields keep current values" $
            clampVideo (VideoOptions [] [] Nothing Nothing Nothing) cam198Video emptyDesiredVideo @?= cam198Video
        ]
    ]

cam196Audio :: AudioConfig
cam196Audio = AudioConfig "G711" "AudioMain" 2 EncG711 64 16

cam198Audio :: AudioConfig
cam198Audio = AudioConfig "A_ENC_000" "A_ENC_000" 2 EncG711 128 8

cam198Video :: VideoConfig
cam198Video = VideoConfig "000" "V_ENC_000" 1 VEncH264 3072 2048 6 15 0 4698 15 (Just "High")
