{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.MediaMtxLive".
--
-- Pins the exact @runOnDemand@ command shapes (the ffmpeg flag set
-- must stay in sync with @Hnvr.Capture.Ffmpeg.recordingArgs@ — same
-- quirk-retag semantics, same reconnect posture) and the YAML\/REST
-- rendering of the dual (ingestion + @-live@) path layout.
module Hnvr.Core.MediaMtxLiveSpec (tests) where

import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson.Types
import qualified Data.Text as T
import Hnvr.Core.MediaMtxLive
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

relay :: T.Text
relay = "rtsp://127.0.0.1:8554"

cam :: CameraPath
cam =
  CameraPath
    { cpSlug = "backyard",
      cpSource = "rtsp://192.168.0.196:554/user=admin&password=x&channel=0&stream=MainStream",
      cpTransport = "udp",
      cpEnabled = True,
      cpLiveAudio = LiveAudio (Just 16000) AudioYes
    }

cfgs :: [(T.Text, Aeson.Value)]
cfgs = pathConfigs relay [cam]

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.MediaMtxLive"
    [ testGroup
        "livePathName"
        [ testCase "suffix" $ assertEqual "name" "backyard-live" (livePathName "backyard")
        ],
      testGroup
        "runOnDemandCmd"
        [ testCase "quirk rate bakes asetrate" $
            assertEqual
              "cmd"
              ( "ffmpeg -hide_banner -loglevel error -fflags +genpts+igndts+discardcorrupt "
                  <> "-rtsp_transport tcp -timeout 5000000 -i rtsp://127.0.0.1:8554/backyard "
                  <> "-map 0:v:0 -map 0:a:0 -c:v copy "
                  <> "-af asetrate=16000,aresample=48000 -c:a libopus -b:a 64k "
                  <> "-f rtsp rtsp://127.0.0.1:8554/backyard-live"
              )
              (runOnDemandCmd relay "backyard" (LiveAudio (Just 16000) AudioYes)),
          testCase "honest audio transcodes without retag" $
            assertEqual
              "no asetrate"
              True
              ( " -map 0:a:0 -c:v copy -ar 48000 -c:a libopus -b:a 64k "
                  `T.isInfixOf` runOnDemandCmd relay "backyard" (LiveAudio Nothing AudioYes)
              ),
          testCase "unknown audio maps optionally" $
            assertEqual
              "optional map"
              True
              ("-map 0:a:0? " `T.isInfixOf` runOnDemandCmd relay "backyard" (LiveAudio Nothing AudioUnknown)),
          testCase "no audio drops the track" $
            assertEqual
              "an"
              True
              (" -map 0:v:0 -an -c:v copy " `T.isInfixOf` runOnDemandCmd relay "backyard" (LiveAudio Nothing AudioNo))
        ],
      testGroup
        "renderPathsYaml"
        [ let y = renderPathsYaml relay [cam]
           in testCase "ingestion path preserved" $
                assertEqual
                  "source"
                  True
                  ( "  backyard:\n    source: rtsp://192.168.0.196:554/user=admin&password=x&channel=0&stream=MainStream\n    rtspTransport: udp\n    sourceOnDemand: yes\n"
                      `T.isInfixOf` y
                  ),
          testCase "live path rendered with quoted command" $
            assertEqual
              "live"
              True
              ( "  backyard-live:\n    runOnDemand: 'ffmpeg"
                  `T.isInfixOf` renderPathsYaml relay [cam]
              ),
          testCase "disabled camera emits nothing" $
            assertEqual
              "disabled"
              False
              ("backyard" `T.isInfixOf` renderPathsYaml relay [cam {cpEnabled = False}])
        ],
      testGroup
        "pathConfigs"
        [ testCase "both paths present with right shapes" $ do
            let allCfgs = pathConfigs relay [cam {cpEnabled = False}, cam]
            assertEqual "count" 2 (length allCfgs)
            assertEqual "ingestion name" "backyard" (fst (head allCfgs))
            assertEqual "live name" "backyard-live" (fst (allCfgs !! 1)),
          testCase "ingestion config shape unchanged" $
            assertEqual
              "source"
              (Just True)
              ( Aeson.Types.parseMaybe
                  (Aeson.withObject "cfg" (Aeson..: "sourceOnDemand"))
                  (snd (head cfgs))
              ),
          testCase "live config carries restart flag" $
            assertEqual
              "restart"
              (Just True)
              ( Aeson.Types.parseMaybe
                  (Aeson.withObject "cfg" (Aeson..: "runOnDemandRestart"))
                  (snd (cfgs !! 1))
              )
        ]
    ]
