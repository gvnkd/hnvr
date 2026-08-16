{-# LANGUAGE OverloadedStrings #-}

-- | Tests for the pure helpers in "Hnvr.Capture.Worker".
--
-- @captureWorker@ itself is integration territory (real ffmpeg + S3 +
-- NATS); see @design_docs/10-test-plan.md@ S2 slice "CaptureWorker
-- integration". This module covers the @backoffDuration@ table and
-- @countRecent@'s 60-second window — both pure functions exported
-- specifically for these tests.
module Hnvr.Capture.WorkerSpec (tests) where

import Control.Concurrent.STM (newTVarIO)
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock
  ( UTCTime (..),
    addUTCTime,
    getCurrentTime,
    secondsToDiffTime,
  )
import qualified Data.UUID as UUID
import Hnvr.Capture.Worker
  ( CameraConfig (..),
    CaptureConfig (..),
    CaptureState (..),
    Transport (..),
    backoffDuration,
    countRecent,
    recordRestart,
    transition,
  )
import Hnvr.Core.Id (CameraId (..), HostId (..))
import Hnvr.Core.Metrics (noOpMetrics)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Capture.Worker"
    [ testGroup
        "backoffDuration"
        [ testCase "n=0 → 2" $ assertEqual "0" 2 (backoffDuration 0),
          testCase "n=1 → 2" $ assertEqual "1" 2 (backoffDuration 1),
          testCase "n=2 → 4" $ assertEqual "2" 4 (backoffDuration 2),
          testCase "n=3 → 8" $ assertEqual "3" 8 (backoffDuration 3),
          testCase "n=4 → 16" $ assertEqual "4" 16 (backoffDuration 4),
          testCase "n=5 → 30" $ assertEqual "5" 30 (backoffDuration 5),
          testCase "n=6 → 30" $ assertEqual "6" 30 (backoffDuration 6),
          testCase "n=99 → 30" $ assertEqual "99" 30 (backoffDuration 99),
          testCase "negative → 2" $ assertEqual "-3" 2 (backoffDuration (-3))
        ],
      testGroup
        "countRecent (60s window)"
        [ testCase "empty ref → 0" $ do
            ref <- newIORef ([] :: [UTCTime])
            n <- countRecent ref t0
            assertEqual "empty" 0 n,
          testCase "one recent → 1" $ do
            ref <- newIORef ([] :: [UTCTime])
            recordRestart ref t0
            n <- countRecent ref t0
            assertEqual "one recent" 1 n,
          testCase "one stale (90s old) → 0" $ do
            ref <- newIORef ([] :: [UTCTime])
            let stale = addUTCTime (-90) t0
            writeIORef ref [stale]
            n <- countRecent ref t0
            assertEqual "stale filtered" 0 n,
          testCase "mixed: 3 recent + 2 stale → 3" $ do
            ref <- newIORef ([] :: [UTCTime])
            let r1 = addUTCTime (-5) t0
                r2 = addUTCTime (-30) t0
                r3 = addUTCTime (-59) t0
                s1 = addUTCTime (-61) t0
                s2 = addUTCTime (-120) t0
            writeIORef ref [r1, r2, r3, s1, s2]
            n <- countRecent ref t0
            assertEqual "3 recent kept" 3 n,
          testCase "countRecent also prunes the ref" $ do
            ref <- newIORef ([] :: [UTCTime])
            let recent = addUTCTime (-10) t0
                stale = addUTCTime (-120) t0
            writeIORef ref [stale, recent]
            _ <- countRecent ref t0
            kept <- readIORef ref
            assertEqual "stale pruned" [recent] kept
        ],
      testGroup
        "transition (dead RTSP endpoint)"
        [ testCase "Pending → Backoff 1 on ffmpeg exit" $ do
            ref <- newIORef []
            stVar <- newTVarIO Pending
            st <- transition stVar cfg deadCam ref Pending
            case st of
              Backoff 1 _ -> pure ()
              other -> assertBool ("expected Backoff 1, got " <> show other) False,
          testCase "5 restarts within 60s → FailedPermanent" $ do
            ref <- newIORef []
            stVar <- newTVarIO Pending
            let drive :: Int -> IO CaptureState
                drive 0 = pure (error "unreached")
                drive 1 = transition stVar cfg deadCam ref Pending
                drive k = do
                  st <- transition stVar cfg deadCam ref Pending
                  case st of
                    Backoff _ _ -> drive (k - 1)
                    other -> pure other
            st <- drive 5
            case st of
              FailedPermanent _ -> pure ()
              other -> assertBool ("expected FailedPermanent, got " <> show other) False,
          testCase "Backoff with elapsed nextAt → Pending" $ do
            ref <- newIORef []
            stVar <- newTVarIO Pending
            now <- getCurrentTime
            st <- transition stVar cfg deadCam ref (Backoff 3 (addUTCTime (-1) now))
            st @?= Pending,
          testCase "FailedPermanent cooldown elapsed → Pending + restart budget reset" $ do
            ref <- newIORef []
            stVar <- newTVarIO Pending
            now <- getCurrentTime
            writeIORef ref [now, now]
            st <- transition stVar cfg deadCam ref (FailedPermanent (addUTCTime (-1) now))
            st @?= Pending
            kept <- readIORef ref
            kept @?= []
        ]
    ]

-- ---- fixture -------------------------------------------------------

-- | Fixed @now@. Tests build other timestamps relative to this so
-- assertions are stable.
t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 8 7) (secondsToDiffTime (12 * 3600))

-- | Process-wide config for transition tests: no NATS, no S3, no-op
-- metrics. The spool dir is never touched — the dead camera's ffmpeg
-- exits before any fragment is produced.
cfg :: CaptureConfig
cfg =
  CaptureConfig
    { capBus = Nothing,
      capS3 = Nothing,
      capBucket = "hnvr-test",
      capHostId = HostId "test-host",
      capSpoolDir = "/tmp/hnvr-workerspec-spool",
      capMetrics = noOpMetrics
    }

-- | Camera pointing at a nonexistent file: ffmpeg's demuxer fails
-- immediately and fatally (unlike a dead RTSP endpoint, which the
-- @-reconnect@ flags in 'recordingArgs' would retry forever). If
-- ffmpeg isn't installed at all, the spawn exception is caught inside
-- 'transition' with the same result. Either way 'Pending' transitions
-- to 'Backoff' quickly and hermetically.
deadCam :: CameraConfig
deadCam =
  CameraConfig
    { ccId = CameraId sampleUuid,
      ccSlug = "dead-cam",
      ccRtspUrl = "file:///nonexistent-cam",
      ccTransport = TcpTransport,
      ccRecordAudio = False,
      ccClipBuffer = Nothing
    }

sampleUuid :: UUID.UUID
sampleUuid =
  case UUID.fromText "00000000-0000-0000-0000-000000000099" of
    Just u -> u
    Nothing -> error "invalid UUID literal in test fixture"
