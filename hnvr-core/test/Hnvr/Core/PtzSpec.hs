{-# LANGUAGE OverloadedStrings #-}

module Hnvr.Core.PtzSpec (tests) where

import Data.Aeson (ToJSON, Value (..), decode, encode, toJSON)
import qualified Data.Aeson.KeyMap as KM
import Hnvr.Core.Ptz
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Ptz"
    [ testGroup
        "PtzCommandMsg JSON"
        [ roundTrip "continuous_move" msgMove,
          roundTrip "stop" msgStop,
          roundTrip "goto_preset" msgGoto,
          roundTrip "set_preset" msgSet,
          roundTrip "go_home" msgHome,
          roundTrip "absolute_move" msgAbs,
          testCase "wire shape: command name + flat args" $ do
            let Object o = toJSONValue msgMove
            KM.lookup "command" o @?= Just (String "continuous_move")
            KM.lookup "args" o
              @?= Just
                ( Object
                    ( KM.fromList
                        [ ("vx", Number 0.5),
                          ("vy", Number (-0.25)),
                          ("zoom", Number 0),
                          ("timeout_ms", Null)
                        ]
                    )
                ),
          testCase "unknown command rejected" $
            (decode "{\"command\":\"pan_tilt_zoom\",\"args\":{},\"source\":\"web_ui\"}" :: Maybe PtzCommandMsg)
              @?= Nothing,
          testCase "unknown source rejected" $
            (decode "{\"command\":\"go_home\",\"args\":{},\"source\":\"cron\"}" :: Maybe PtzCommandMsg)
              @?= Nothing
        ],
      testGroup
        "PtzReply JSON"
        [ testCase "ok with token round-trips" $ do
            let r = PtzReplyOk (Just (toJSON (PresetToken "42")))
            decode (encode r) @?= Just r,
          testCase "error round-trips" $
            decode (encode (PtzReplyError "SOAP fault: no preset")) @?= Just (PtzReplyError "SOAP fault: no preset")
        ],
      testGroup
        "state machine"
        [ testCase "continuous_move -> manual_move" $
            stateAfter (CmdContinuousMove (Velocity 1 0 0) Nothing) @?= PtzManualMove,
          testCase "stop -> idle" $
            stateAfter (CmdStop (StopAxes True True)) @?= PtzIdle,
          testCase "goto_preset -> going_to_preset" $
            stateAfter (CmdGotoPreset (PresetToken "1")) @?= PtzGoingToPreset,
          testCase "go_home -> returning_home" $
            stateAfter CmdGoHome @?= PtzReturningHome,
          testCase "set_preset -> idle (no movement)" $
            stateAfter (CmdSetPreset (PresetName "door")) @?= PtzIdle
        ],
      testGroup
        "PtzStatusMsg JSON"
        [ testCase "round-trip with position" $ do
            let m = PtzStatusMsg PtzManualMove (Just (PtzPosition 0.5 0 0.25)) "continuous_move" "2026-08-16T12:00:00Z"
            decode (encode m) @?= Just m,
          testCase "round-trip without position (nil status camera)" $ do
            let m = PtzStatusMsg PtzIdle Nothing "stop" "2026-08-16T12:00:00Z"
            decode (encode m) @?= Just m
        ],
      testGroup
        "PtzAuditRecord JSON"
        [ testCase "round-trip" $ do
            let r =
                  PtzAuditRecord
                    { parCameraId = "5f9c0d70-0000-0000-0000-000000000001",
                      parUserId = Just "5f9c0d70-0000-0000-0000-000000000002",
                      parCommand = "continuous_move",
                      parArgs = commandArgs (CmdContinuousMove (Velocity 0.5 0 0) Nothing),
                      parSource = SrcWebUi,
                      parDurationMs = Just 800,
                      parOk = True,
                      parError = Nothing
                    }
            decode (encode r) @?= Just r
        ],
      testGroup
        "source encoding matches ptz_source PG enum"
        [ testCase "web_ui" $ ptzSourceText SrcWebUi @?= "web_ui",
          testCase "auto_track" $ ptzSourceText SrcAutoTrack @?= "auto_track",
          testCase "idle_timeout" $ ptzSourceText SrcIdleTimeout @?= "idle_timeout",
          testCase "api" $ ptzSourceText SrcApi @?= "api",
          testCase "schedule" $ ptzSourceText SrcSchedule @?= "schedule"
        ]
    ]
  where
    roundTrip name m = testCase ("round-trip " <> name) $ decode (encode m) @?= Just m
    toJSONValue :: (ToJSON a) => a -> Value
    toJSONValue = toJSON

    msgMove = PtzCommandMsg (CmdContinuousMove (Velocity 0.5 (-0.25) 0) Nothing) SrcWebUi (Just "uid-1") (Just 800)
    msgStop = PtzCommandMsg (CmdStop (StopAxes True False)) SrcWebUi Nothing Nothing
    msgGoto = PtzCommandMsg (CmdGotoPreset (PresetToken "7")) SrcWebUi Nothing Nothing
    msgSet = PtzCommandMsg (CmdSetPreset (PresetName "door")) SrcApi Nothing Nothing
    msgHome = PtzCommandMsg CmdGoHome SrcIdleTimeout Nothing Nothing
    msgAbs = PtzCommandMsg (CmdAbsoluteMove (PtzPosition 0 0 0)) SrcSchedule Nothing Nothing
