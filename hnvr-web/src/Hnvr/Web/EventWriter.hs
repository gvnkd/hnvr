{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Leader-side EventWriter.
--
-- Subscribes to the @hnvr.events@ NATS subject and persists every
-- @segment_written@ event into the @segments@ table. This is the
-- leader's read-side of the capture pipeline: workers (CaptureWorker
-- running on any host) publish 'SegmentWritten' envelopes after each
-- fragment upload, and the EventWriter drains them into Postgres so the
-- archive UI has something to query.
--
-- Failure modes:
--   * NATS unreachable at leader boot: warning logged, no events drained
--     until next leader restart. Capture is unaffected (workers don't
--     need the leader to write to S3).
--   * Insert fails (e.g. unique violation from a duplicate publish):
--     logged and skipped; we don't block the drain loop.
module Hnvr.Web.EventWriter
  ( startEventWriter
  ) where

import Control.Concurrent.Async (async)
import Control.Exception (SomeException, catch)
import Control.Monad (forever)
import Data.Aeson (FromJSON, decode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import IHP.HaskellSupport ((|>), set)
import IHP.ModelSupport (ModelContext, createRecord, newRecord)
import Generated.Types (Segment)

import Hnvr.Core.Id (CameraId (..), HostId (..), sha256ToHex)
import Hnvr.Core.Segment (SegmentWritten (..))
import Hnvr.Nats.Bus (Bus, Message (..), Subscription)
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Nats.Subjects (events)

-- | Spawn the EventWriter drain loop in a background 'async'. Returns
-- immediately after subscribing. The async lives for the lifetime of the
-- process; if NATS disconnects, the nats-queue subscriber thread dies
-- silently (we'd need JetStream durability to recover, deferred to
-- Slice 5b).
startEventWriter :: Bus -> ModelContext -> IO ()
startEventWriter bus mc = do
  sub <- Bus.subscribe bus events
  let ?modelContext = mc
  _ <- async (drainLoop sub)
  putStrLn "HNVR EventWriter: subscribed to hnvr.events"

drainLoop :: (?modelContext :: ModelContext) => Subscription -> IO ()
drainLoop sub = forever $ do
  msg <- Bus.readMessage sub
  case decodeStrict (msgPayload msg) :: Maybe SegmentWritten of
    Just sw ->
      insertSegment sw
        `catch` \(e :: SomeException) ->
          putStrLn ("HNVR EventWriter: insert failed for "
                    <> T.unpack (swSlug sw) <> ": " <> show e)
    Nothing ->
      -- Not a SegmentWritten envelope (or parse error). Future event
      -- kinds (line_crossed etc.) land in Phase 4; for now we silently
      -- drop anything we can't decode.
      pure ()

-- | Insert a 'SegmentWritten' row via IHP's createRecord.
--
-- Idempotency relies on the @UNIQUE (camera_id, start_ts)@ constraint:
-- a duplicate insert throws a unique-violation PG error which the
-- 'drainLoop' catch handler absorbs. We don't use ON CONFLICT DO NOTHING
-- here because IHP's createRecord doesn't expose it; we'd need raw SQL
-- for that (deferred — the catch path handles dupes correctly, just
-- slightly noisier in logs).
insertSegment :: (?modelContext :: ModelContext) => SegmentWritten -> IO ()
insertSegment sw = do
  let seg =
        newRecord @Segment
          |> set #cameraId (unCameraId (swCamera sw) :: UUID)
          |> set #startTs (swStart sw)
          |> set #endTs (swEnd sw)
          |> set #hostId (Just (unHostId (swHostId sw)) :: Maybe Text)
          |> set #objectKey (swObjectKey sw)
          |> set #bytes (fromIntegral (swBytes sw) :: Integer)
          |> set #sha256 (sha256ToHex (swSha sw))
  _ <- createRecord seg
  pure ()

decodeStrict :: FromJSON a => BS.ByteString -> Maybe a
decodeStrict = decode . BL.fromStrict
