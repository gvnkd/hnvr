{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.CameraStatus": wire round-trip, health-payload
-- parsing tolerance, and the status resolution table.
module Hnvr.Core.CameraStatusSpec (tests) where

import Data.Aeson (Value, object, (.=))
import qualified Data.Aeson as Aeson
import Hnvr.Core.CameraStatus
  ( CameraHealth (..),
    CameraStatus (..),
    CaptureStateWire (..),
    HostView (..),
    cameraHealthFromPayload,
    captureStateWireFromText,
    captureStateWireToText,
    resolveCameraStatus,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.CameraStatus"
    [ testGroup
        "wire text round-trip"
        [ testCase "all constructors round-trip" $
            mapM_
              (\st -> captureStateWireFromText (captureStateWireToText st) @?= Just st)
              [minBound .. maxBound],
          testCase "unknown text → Nothing" $
            captureStateWireFromText "banana" @?= Nothing
        ],
      testGroup
        "cameraHealthFromPayload"
        [ testCase "parses the cameras array" $ do
            let v =
                  object
                    [ "host" .= ("hnvr-2" :: String),
                      "cameras"
                        .= [ object ["slug" .= ("backyard" :: String), "state" .= ("running" :: String)],
                             object ["slug" .= ("low_ent" :: String), "state" .= ("backoff" :: String)]
                           ]
                    ]
            cameraHealthFromPayload v
              @?= [ CameraHealth "backyard" WRunning,
                    CameraHealth "low_ent" WBackoff
                  ],
          testCase "missing cameras key → []" $
            cameraHealthFromPayload (object ["host" .= ("hnvr-2" :: String)]) @?= [],
          testCase "non-object payload → []" $
            cameraHealthFromPayload (Aeson.String "junk") @?= [],
          testCase "unknown state in entry → whole array rejected" $ do
            let v =
                  object
                    [ "cameras"
                        .= [object ["slug" .= ("a" :: String), "state" .= ("zzz" :: String)]]
                    ]
            cameraHealthFromPayload v @?= [],
          testCase "ToJSON/FromJSON entry round-trip" $ do
            let ch = CameraHealth "backyard" WFailed
                v = object ["cameras" .= [ch]]
            cameraHealthFromPayload v @?= [ch]
        ],
      testGroup
        "resolveCameraStatus"
        [ testCase "disabled wins over a healthy running host" $
            resolveCameraStatus False (Just (HostView True (Just WRunning))) @?= CSDisabled,
          testCase "enabled + no assigned host → Unassigned" $
            resolveCameraStatus True Nothing @?= CSUnassigned,
          testCase "stale heartbeat → HostDown even with running entry" $
            resolveCameraStatus True (Just (HostView False (Just WRunning))) @?= CSHostDown,
          testCase "fresh host, camera absent from payload → NotRunning" $
            resolveCameraStatus True (Just (HostView True Nothing)) @?= CSNotRunning,
          testCase "running → Recording" $
            resolveCameraStatus True (Just (HostView True (Just WRunning))) @?= CSRecording,
          testCase "pending → Starting" $
            resolveCameraStatus True (Just (HostView True (Just WPending))) @?= CSStarting,
          testCase "backoff → Reconnecting" $
            resolveCameraStatus True (Just (HostView True (Just WBackoff))) @?= CSReconnecting,
          testCase "failed → Failed" $
            resolveCameraStatus True (Just (HostView True (Just WFailed))) @?= CSFailed,
          testCase "stopped → NotRunning" $
            resolveCameraStatus True (Just (HostView True (Just WStopped))) @?= CSNotRunning
        ]
    ]
