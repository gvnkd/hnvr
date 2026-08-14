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
  ( startEventWriter,
  )
where

import Control.Concurrent.Async (async)
import Control.Exception (SomeException, catch)
import Control.Monad (forever, void)
import Data.Aeson (FromJSON, decode)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import Hnvr.Core.Event (CvEvent (..))
import Hnvr.Core.Id (CameraId (..), HostId (..), sha256ToHex)
import Hnvr.Core.Logging (logError, logInfo)
import Hnvr.Core.Segment (SegmentWritten (..))
import Hnvr.Nats.Bus (Bus, Message (..), Subscription)
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Nats.Subjects (events)
import IHP.ModelSupport (ModelContext, sqlExec)

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
  logInfo "EventWriter: subscribed to hnvr.events"

drainLoop :: (?modelContext :: ModelContext) => Subscription -> IO ()
drainLoop sub = forever $ do
  msg <- Bus.readMessage sub
  case decodeStrict (msgPayload msg) :: Maybe SegmentWritten of
    Just sw ->
      insertSegment sw
        `catch` \(e :: SomeException) ->
          logError
            ( "EventWriter: insert failed for "
                <> swSlug sw
                <> ": "
                <> T.pack (show e)
            )
    Nothing ->
      case decodeStrict (msgPayload msg) :: Maybe CvEvent of
        Just ev ->
          insertCvEvent ev
            `catch` \(e :: SomeException) ->
              logError ("EventWriter: CV event insert failed: " <> T.pack (show e))
        Nothing ->
          -- Unknown envelope shape (or parse error) — drop silently.
          pure ()

-- | Insert a CV event (line_crossed / zone_*) into the @events@ table.
-- @segment_ts@ is left NULL in this slice.
insertCvEvent :: (?modelContext :: ModelContext) => CvEvent -> IO ()
insertCvEvent ev =
  void $
    sqlExec
      "INSERT INTO events \
      \  (camera_id, rule_id, ts, kind, class_id, track_id, confidence, \
      \   bbox, thumbnail_key, host_id, created_at) \
      \ VALUES (?, ?::uuid, ?, ?::event_kind, ?, ?, ?, ?::jsonb, ?, ?, NOW())"
      ( unCameraId (ceCamera ev) :: UUID,
        ceRuleId ev,
        ceTs ev,
        ceKind ev,
        ceClassId ev,
        ceTrackId ev,
        ceConfidence ev,
        ceBbox ev,
        ceThumbnailKey ev,
        unHostId (ceHost ev) :: Text
      )

-- | Insert a 'SegmentWritten' row idempotently.
--
-- Uses raw SQL with @ON CONFLICT (camera_id, start_ts) DO NOTHING@ so
-- duplicate publishes (reconnect retries, JetStream redeliveries once
-- we wire it) are absorbed silently — no exception, no log noise, no
-- extra round-trip. The unique constraint is declared in
-- @Application/Schema.sql@.
insertSegment :: (?modelContext :: ModelContext) => SegmentWritten -> IO ()
insertSegment sw =
  void $
    sqlExec
      "INSERT INTO segments \
      \  (camera_id, start_ts, end_ts, host_id, object_key, bytes, sha256, \
      \   has_audio, created_at) \
      \ VALUES (?, ?, ?, ?, ?, ?, ?, FALSE, NOW()) \
      \ ON CONFLICT (camera_id, start_ts) DO NOTHING"
      ( unCameraId (swCamera sw) :: UUID,
        swStart sw,
        swEnd sw,
        unHostId (swHostId sw) :: Text,
        swObjectKey sw,
        fromIntegral (swBytes sw) :: Integer,
        sha256ToHex (swSha sw)
      )

decodeStrict :: (FromJSON a) => BS.ByteString -> Maybe a
decodeStrict = decode . BL.fromStrict
