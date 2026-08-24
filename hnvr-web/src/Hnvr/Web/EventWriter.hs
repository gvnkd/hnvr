{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE NumericUnderscores #-}
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

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Exception (SomeException, bracket, catch)
import Control.Monad (forever, void)
import Data.Aeson (FromJSON, decode, encode, toJSON)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Data.UUID (UUID)
import qualified Database.PostgreSQL.Simple as PG
import Database.PostgreSQL.Simple.Types ((:.) (..))
import Hnvr.Core.Event (ClipReady (..), CvEvent (..), SnapshotWritten (..))
import Hnvr.Core.Id (CameraId (..), HostId (..), sha256ToHex)
import Hnvr.Core.Logging (logError, logInfo)
import Hnvr.Core.Segment (SegmentWritten (..))
import Hnvr.Nats.Bus (Bus, Message (..), Subscription)
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Nats.Subjects (events)
import IHP.ModelSupport (ModelContext, sqlExec)
import qualified System.Environment as Env

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
  _ <- async segmentTsBackfillLoop
  logInfo "EventWriter: subscribed to hnvr.events"

-- | Best-effort backfill of @events.segment_ts@. The immediate scalar
-- subquery in 'insertCvEvent' usually misses: the covering segment row
-- is only written after its fragment closes (up to ~2 s later), while
-- the event fires in real time. Re-resolve recent NULL rows every
-- minute; rows whose camera genuinely wasn't recording age out of the
-- 1-day window and stay NULL.
segmentTsBackfillLoop :: (?modelContext :: ModelContext) => IO ()
segmentTsBackfillLoop = forever $ do
  threadDelay 60_000_000
  void
    ( sqlExec
        "UPDATE events e SET segment_ts = \
        \  (SELECT s.start_ts FROM segments s \
        \    WHERE s.camera_id = e.camera_id \
        \      AND s.start_ts <= e.ts AND s.end_ts >= e.ts \
        \      AND s.pending_delete_at IS NULL \
        \    ORDER BY s.start_ts DESC LIMIT 1) \
        \WHERE e.segment_ts IS NULL \
        \  AND e.ts < NOW() - INTERVAL '15 seconds' \
        \  AND e.ts > NOW() - INTERVAL '1 day'"
        ()
    )
    `catch` \(e :: SomeException) ->
      logError ("EventWriter: segment_ts backfill failed: " <> T.pack (show e))

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
          case decodeStrict (msgPayload msg) :: Maybe ClipReady of
            Just cr ->
              insertClipReady cr
                `catch` \(e :: SomeException) ->
                  logError ("EventWriter: clip insert failed: " <> T.pack (show e))
            Nothing ->
              case decodeStrict (msgPayload msg) :: Maybe SnapshotWritten of
                Just sn ->
                  insertSnapshot sn
                    `catch` \(e :: SomeException) ->
                      logError ("EventWriter: snapshot insert failed: " <> T.pack (show e))
                Nothing ->
                  -- Unknown envelope shape (or parse error) — drop silently.
                  pure ()

-- | Persist a finished event clip (separated event video store) and
-- link every event it covers. Linkage is by camera + time window: a
-- clip that merged several rule fires picks up all of them, including
-- events from rules other than the opener. Idempotent on the clip
-- prefix — a duplicate 'ClipReady' publish inserts no second row.
insertClipReady :: (?modelContext :: ModelContext) => ClipReady -> IO ()
insertClipReady cr = do
  void $
    sqlExec
      "INSERT INTO event_clips \
      \  (camera_id, rule_id, started_at, duration_sec, object_prefix, \
      \   retention_hours, created_at) \
      \ SELECT ?, ?::uuid, ?, ?, ?, ?, NOW() \
      \ WHERE NOT EXISTS \
      \  (SELECT 1 FROM event_clips WHERE object_prefix = ?)"
      ( unCameraId (crCamera cr) :: UUID,
        crRuleId cr,
        crStartedAt cr,
        crDurationSec cr,
        crObjectPrefix cr,
        crRetentionHours cr,
        crObjectPrefix cr
      )
  void $
    sqlExec
      "INSERT INTO event_clip_events (clip_id, event_id, created_at) \
      \ SELECT c.id, e.id, NOW() \
      \ FROM event_clips c, events e \
      \ WHERE c.object_prefix = ? \
      \   AND e.camera_id = ? \
      \   AND e.ts >= c.started_at \
      \   AND e.ts <= c.started_at + (c.duration_sec * INTERVAL '1 second') \
      \ ON CONFLICT (clip_id, event_id) DO NOTHING"
      (crObjectPrefix cr, unCameraId (crCamera cr) :: UUID)

-- | Insert a CV event (line_crossed / zone_*) into the @events@ table.
-- @segment_ts@ links the event to the covering archive segment
-- (best-effort: usually NULL at insert time because the segment row
-- lags the fragment close — 'segmentTsBackfillLoop' re-resolves it
-- within a minute). @payload@ stores the full 'CvEvent' JSON envelope.
--
-- Idempotent: @ON CONFLICT (camera_id, rule_id, track_id, ts) DO
-- NOTHING@ absorbs duplicate publishes — a second leader draining
-- @hnvr.events@ (the Aug 21 2026 duplicate-rows bug) or any future
-- redelivery. Same pattern as 'insertSegment'/'insertSnapshot';
-- constraint added by migration 0014.
--
-- Uses a one-shot postgresql-simple connection (like
-- 'Web.Controller.Events.fetchEventRows'): the 14-param INSERT exceeds
-- IHP sqlExec's ToSnippetParams arity.
insertCvEvent :: CvEvent -> IO ()
insertCvEvent ev = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  void $
    bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn ->
      PG.execute
        conn
        "INSERT INTO events \
        \  (camera_id, rule_id, ts, kind, class_id, track_id, confidence, \
        \   bbox, thumbnail_key, host_id, segment_ts, payload, created_at) \
        \ VALUES (?, ?::uuid, ?, ?::event_kind, ?, ?, ?, ?::jsonb, ?, ?, \
        \  (SELECT s.start_ts FROM segments s \
        \    WHERE s.camera_id = ? AND s.start_ts <= ? AND s.end_ts >= ? \
        \      AND s.pending_delete_at IS NULL \
        \    ORDER BY s.start_ts DESC LIMIT 1), \
        \  ?::jsonb, NOW()) \
        \ ON CONFLICT (camera_id, rule_id, track_id, ts) DO NOTHING"
        ( ( unCameraId (ceCamera ev) :: UUID,
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
            :. ( unCameraId (ceCamera ev) :: UUID,
                 ceTs ev,
                 ceTs ev,
                 TL.toStrict (TLE.decodeUtf8 (encode (toJSON ev)))
               )
        )

defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"

-- | Insert a periodic camera snapshot row (archive-timeline thumbnail
-- store, design_docs/12-timeline-archive.md). Idempotent on
-- @(camera_id, ts)@ — same duplicate-publish absorption as
-- 'insertSegment'.
insertSnapshot :: (?modelContext :: ModelContext) => SnapshotWritten -> IO ()
insertSnapshot sn =
  void $
    sqlExec
      "INSERT INTO camera_snapshots \
      \  (camera_id, ts, object_key, bytes, created_at) \
      \ VALUES (?, ?, ?, ?, NOW()) \
      \ ON CONFLICT (camera_id, ts) DO NOTHING"
      ( unCameraId (snCamera sn) :: UUID,
        snTs sn,
        snObjectKey sn,
        fromIntegral (snBytes sn) :: Integer
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
      \ VALUES (?, ?, ?, ?, ?, ?, ?, ?, NOW()) \
      \ ON CONFLICT (camera_id, start_ts) DO NOTHING"
      ( unCameraId (swCamera sw) :: UUID,
        swStart sw,
        swEnd sw,
        unHostId (swHostId sw) :: Text,
        swObjectKey sw,
        fromIntegral (swBytes sw) :: Integer,
        sha256ToHex (swSha sw),
        swHasAudio sw
      )

decodeStrict :: (FromJSON a) => BS.ByteString -> Maybe a
decodeStrict = decode . BL.fromStrict
