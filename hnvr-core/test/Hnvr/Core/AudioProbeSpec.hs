{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.AudioProbe".
--
-- The synthetic packet traces encode the shapes observed against
-- Sergey's cameras (Aug 28 2026): a connect burst (several hundred kB
-- arriving in the first instants) followed by a steady production
-- rate; a 16 kHz G.711 quirk measures ~16 000 B\/s of payload.
module Hnvr.Core.AudioProbeSpec (tests) where

import Hnvr.Core.AudioProbe
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

-- | n packets of @sz@ bytes every @dt@ seconds starting at t0.
steady :: Double -> Int -> Int -> Double -> [(Double, Int)]
steady t0 n sz dt = [(t0 + fromIntegral i * dt, sz) | i <- [0 .. n - 1]]

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.AudioProbe"
    [ testGroup
        "parseCodecFields"
        [ testCase "codec first" $
            assertEqual
              "pcm_mulaw,8000"
              (Just ("pcm_mulaw", 8000))
              (parseCodecFields "pcm_mulaw,8000"),
          testCase "rate first" $
            assertEqual
              "8000,pcm_alaw"
              (Just ("pcm_alaw", 8000))
              (parseCodecFields "8000,pcm_alaw"),
          testCase "spaces are tolerated" $
            assertEqual
              "stripped"
              (Just ("g726", 8000))
              (parseCodecFields "g726, 8000"),
          testCase "garbage is rejected" $
            assertEqual "one field" Nothing (parseCodecFields "pcm_mulaw")
        ],
      testGroup
        "codec facts"
        [ testCase "fixed-clock family" $ do
            assertEqual "mulaw" True (isFixedClockCodec "pcm_mulaw")
            assertEqual "alaw" True (isFixedClockCodec "pcm_alaw")
            assertEqual "g726" True (isFixedClockCodec "g726")
            assertEqual "aac" False (isFixedClockCodec "aac"),
          testCase "bits per sample" $ do
            assertEqual "mulaw" (Just 8) (bitsPerSample "pcm_mulaw")
            assertEqual "g726" (Just 4) (bitsPerSample "g726")
            assertEqual "aac" Nothing (bitsPerSample "aac")
        ],
      testGroup
        "nearestRateHz"
        [ testCase "exact" $ assertEqual "16k" (Just 16000) (nearestRateHz 16000),
          testCase "noise snaps" $ assertEqual "16.2k" (Just 16000) (nearestRateHz 16200),
          testCase "below 8k family rejected" $ assertEqual "5k" Nothing (nearestRateHz 5000),
          testCase "far above family rejected" $ assertEqual "90k" Nothing (nearestRateHz 90000)
        ],
      testGroup
        "trueRateHz"
        [ testCase "steady 16 kHz payload measures 16000" $
            -- 320 B every 20 ms = 16000 B/s.
            assertEqual
              "16k"
              (Just 16000)
              (trueRateHz 8 (steady 0 100 320 0.02)),
          testCase "connect burst does not skew the slope" $
            -- 60 kB of burst packets in the first 100 ms, then the
            -- same steady 16 kHz body: the least-squares slope over
            -- the window still lands on the 16 kHz bucket.
            let burst = steady 0 20 3000 0.005
                body = steady 0.5 150 320 0.02
             in assertEqual
                  "burst-insensitive"
                  (Just 16000)
                  (trueRateHz 8 (burst <> body)),
          testCase "g726 halves the bytes" $
            -- 160 B every 20 ms = 8000 B/s at 4 bits/sample = 16 kHz.
            assertEqual
              "g726 16k"
              (Just 16000)
              (trueRateHz 4 (steady 0 100 160 0.02)),
          testCase "honest 8 kHz payload measures 8000" $
            assertEqual
              "8k"
              (Just 8000)
              (trueRateHz 8 (steady 0 100 160 0.02)),
          testCase "too few packets" $
            assertEqual "short" Nothing (trueRateHz 8 (steady 0 5 320 0.02)),
          testCase "too short a window" $
            assertEqual "window" Nothing (trueRateHz 8 (steady 0 20 320 0.02))
        ],
      testGroup
        "quirkAsetrateHz"
        [ testCase "2x quirk retags" $
            assertEqual "16 over 8" (Just 16000) (quirkAsetrateHz 8000 16000),
          testCase "honest camera untouched" $
            assertEqual "8 over 8" Nothing (quirkAsetrateHz 8000 8000),
          testCase "mild misread does not retag" $
            assertEqual "9 over 8" Nothing (quirkAsetrateHz 8000 9000),
          testCase "4x quirk retags" $
            assertEqual "32 over 8" (Just 32000) (quirkAsetrateHz 8000 32000)
        ],
      testGroup
        "probe argv"
        [ testCase "codec probe targets stream fields" $
            assertEqual
              "csv"
              True
              ( "stream=codec_name,sample_rate"
                  `elem` codecProbeArgs "rtsp://127.0.0.1:8554/backyard"
              ),
          testCase "packet probe targets packet fields" $
            assertEqual
              "csv"
              True
              ( "packet=size,pts_time"
                  `elem` packetProbeArgs "rtsp://127.0.0.1:8554/backyard"
              )
        ]
    ]
