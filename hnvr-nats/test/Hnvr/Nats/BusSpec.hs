{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Nats.Bus".
--
-- Mixes pure unit tests for @hostFromUri@ (including the documented
-- pitfall #31 — bare URI without credentials produces an empty host)
-- with an env-gated integration test exercising the real NATS bus
-- against the devenv-managed @nats-server@ on @localhost:4222@.
module Hnvr.Nats.BusSpec (tests) where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try)
import Control.Monad (void)
import Data.Aeson (encode)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (fromMaybe)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), secondsToDiffTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Hnvr.Core.Id
  ( CameraId (..),
    HostId (..),
    Sha256 (..),
  )
import Hnvr.Core.Segment (SegmentKind (..), SegmentWritten (..))
import Hnvr.Nats.Bus
  ( Message (msgPayload),
    defaultConfig,
    hostFromUri,
    publishJson,
    readMessage,
    subscribe,
    withBus,
  )
import Hnvr.Nats.Subjects (events)
import Network.Nats (NatsHost (..))
import System.Environment (lookupEnv)
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Nats.Bus"
    [ testGroup
        "hostFromUri (pure)"
        [ testCase "parses user:pass@host:port" $ do
            let h = hostFromUri "nats://u:p@h.example:4222"
            assertEqual "host" "h.example" (natsHHost h)
            assertEqual "port" 4222 (natsHPort h)
            assertEqual "user" "u" (natsHUser h)
            assertEqual "pass" "p" (natsHPass h),
          testCase "parses default port when omitted" $ do
            let h = hostFromUri "nats://u:p@h.example"
            assertEqual "port" 4222 (natsHPort h),
          testCase "parses default pass when omitted" $ do
            let h = hostFromUri "nats://u@h.example"
            assertEqual "pass" "nats" (natsHPass h),
          -- Pitfall #31: a bare URI without credentials yields an empty
          -- host. Documented in MEMORIES.md; the test pins the behaviour
          -- so a refactor doesn't silently change it without a design
          -- decision.
          testCase "bare URI without credentials yields empty host (pitfall #31)" $ do
            let h = hostFromUri "nats://localhost:4222"
            assertEqual "host is empty (known bug)" "" (natsHHost h)
        ],
      testGroup
        "bus integration (env-gated)"
        [ integrationTest "publishJson + subscribe round-trips SegmentWritten" $
            withBus defaultConfig $ \bus -> do
              sub <- subscribe bus events
              -- Slight delay so the subscription is registered before
              -- the publish reaches the server.
              threadDelay 50_000
              publishJson bus events sampleWritten
              mMsg <- timeoutUs 2_000_000 "readMessage" (readMessage sub)
              let payload = BL.toStrict (encode sampleWritten)
              assertEqual "roundtrip payload" payload (msgPayload mMsg)
        ]
    ]

-- ---- fixtures ------------------------------------------------------

sampleWritten :: SegmentWritten
sampleWritten =
  SegmentWritten
    { swCamera = CameraId sampleUuid,
      swSlug = "cam-197",
      swStart = sampleTs,
      swEnd = sampleTs,
      swBytes = 1234,
      swSha = Sha256 (B.replicate 32 0xAB),
      swKind = Video,
      swHasAudio = True,
      swHostId = "hnvr-2",
      swObjectKey = "cam-197/2026-08-07/12-00-00.mp4"
    }

sampleUuid :: UUID
sampleUuid = fromMaybe (error "bad uuid") (UUID.fromText "00000000-0000-0000-0000-000000000001")

sampleTs :: UTCTime
sampleTs = UTCTime (fromGregorian 2026 8 7) (secondsToDiffTime (12 * 3600 + 0 * 60 + 0))

-- ---- integration helpers ------------------------------------------

-- | Wrap a test so it runs only when HNVR_TEST_INTEGRATION=1; otherwise
-- it succeeds silently (Tasty prints the test name as passing).
integrationTest :: String -> IO () -> TestTree
integrationTest name action =
  testCase name $ do
    mEnv <- lookupEnv "HNVR_TEST_INTEGRATION"
    case mEnv of
      Just "1" -> action
      _ -> pure ()

-- | Wrap an IO action in a microsecond timeout. Better than hanging
-- the suite when a NATS message never arrives.
timeoutUs :: Int -> String -> IO a -> IO a
timeoutUs micros label action = do
  mRes <- timeout micros action
  case mRes of
    Just a -> pure a
    Nothing -> assertFailure (label <> " timed out after " <> show micros <> "µs")
