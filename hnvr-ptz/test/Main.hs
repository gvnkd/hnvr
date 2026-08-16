{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import qualified Data.ByteString as BS
import Hnvr.Core.Onvif
import Hnvr.Onvif.Client
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (assertFailure, testCase, (@?=))

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "hnvr-ptz"
    [ testGroup
        "parseAudioConfigs"
        [ testCase "cam-196 (Hikvision-OEM: bps/Hz normalized)" $ do
            bs <- BS.readFile "test/fixtures/audio-configs-196.xml"
            case parseAudioConfigs bs of
              Left e -> assertFailure (show e)
              Right cs ->
                cs @?= [AudioConfig "G711" "AudioMain" 2 EncG711 64 16],
          testCase "cam-198 (XM: spec units)" $ do
            bs <- BS.readFile "test/fixtures/audio-configs-198.xml"
            case parseAudioConfigs bs of
              Left e -> assertFailure (show e)
              Right cs ->
                cs @?= [AudioConfig "A_ENC_000" "A_ENC_000" 2 EncG711 128 8]
        ],
      testGroup
        "parseAudioOptions"
        [ testCase "cam-196 offers G711 + AAC" $ do
            bs <- BS.readFile "test/fixtures/audio-options-196.xml"
            case parseAudioOptions bs of
              Left e -> assertFailure (show e)
              Right o -> aoEncodings o @?= [EncG711, EncAAC],
          testCase "cam-198 offers G711 only, constrained bitrate/rate" $ do
            bs <- BS.readFile "test/fixtures/audio-options-198.xml"
            case parseAudioOptions bs of
              Left e -> assertFailure (show e)
              Right o -> do
                aoEncodings o @?= [EncG711]
                aoBitratesKbps o @?= [128]
                aoSampleRatesKhz o @?= [8]
        ],
      testGroup
        "parseVideoConfigs"
        [ testCase "cam-196 main+sub (nested H264 GovLength)" $ do
            bs <- BS.readFile "test/fixtures/video-configs-196.xml"
            case parseVideoConfigs bs of
              Left e -> assertFailure (show e)
              Right cs -> do
                length cs @?= 2
                let main = head cs
                vcName main @?= "VideoEncodeMain"
                vcWidth main @?= 4000
                vcHeight main @?= 3000
                vcFps main @?= 15
                vcBitrateKbps main @?= 4698
                vcGovLength main @?= 15
                vcCodecProfile main @?= Just "High",
          testCase "cam-198 three configs (flat GovLength)" $ do
            bs <- BS.readFile "test/fixtures/video-configs-198.xml"
            case parseVideoConfigs bs of
              Left e -> assertFailure (show e)
              Right cs -> do
                length cs @?= 3
                let main = head cs
                vcName main @?= "V_ENC_000"
                vcWidth main @?= 3072
                vcHeight main @?= 2048
                vcFps main @?= 15
                vcGovLength main @?= 15
                vcEncoding (cs !! 2) @?= VEncJpeg
        ],
      testGroup
        "parseVideoOptions"
        [ testCase "cam-198 resolution list includes native" $ do
            bs <- BS.readFile "test/fixtures/video-options-198.xml"
            case parseVideoOptions bs of
              Left e -> assertFailure (show e)
              Right o -> do
                (3072, 2048) `elem` voResolutions o @?= True
                VEncH264 `elem` voEncodings o @?= True
        ],
      testGroup
        "parseProfilesVideoConfigs (OpenIPC/Majestic ver20 media)"
        [ testCase "cam-198 OpenIPC: two profiles, main 2592x1520 + sub 640x360" $ do
            bs <- BS.readFile "test/fixtures/profiles-198-openipc.xml"
            case parseProfilesVideoConfigs bs of
              Left e -> assertFailure (show e)
              Right cs -> do
                length cs @?= 2
                let (Just main_, Just sub) = pickMainSub cs
                vcName main_ @?= "V_ENC_000"
                (vcWidth main_, vcHeight main_) @?= (2592, 1520)
                vcFps main_ @?= 15
                vcBitrateKbps main_ @?= 4096
                (vcWidth sub, vcHeight sub) @?= (640, 360)
                vcEncoding main_ @?= VEncH264
        ]
    ]
