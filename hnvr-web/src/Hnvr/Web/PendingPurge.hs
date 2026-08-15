{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Verified recording deletion (tombstone pattern, migration 0006).
--
-- 'Web.Controller.Archive.PurgeRecordingAction' no longer deletes
-- segment rows: it stamps @pending_delete_at = NOW()@ synchronously
-- (every read path filters @pending_delete_at IS NULL@, so the
-- recording vanishes from the UI immediately) and forks
-- 'forkCameraPurge'. The worker:
--
--   1. collects the batch's row keys,
--   2. deletes them from S3 plus any orphans found by day-prefix
--      listing (minus a protect set of still-live rows' keys),
--   3. RE-LISTS the window and only hard-DELETEs the rows when zero
--      deletable objects remain — Sergey's 2026-08-15 requirement:
--      "check if data actually deleted from s3, and only then clear
--      db rows",
--   4. leaves the rows in place otherwise; 'startPendingPurgeSweeper'
--      re-runs the batch every 60 s until it converges.
--
-- The sweeper is also the crash-recovery path: if the leader dies
-- mid-purge (the exact failure that orphaned 98.6k objects / 41 GiB
-- on 2026-08-15), the tombstoned rows survive and the next leader's
-- sweeper resumes them. Idempotent throughout: S3 deletes of missing
-- keys are no-ops, the row DELETE is keyed on the batch stamp.
module Hnvr.Web.PendingPurge
  ( startPendingPurgeSweeper,
    forkCameraPurge,
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Exception (SomeException, bracket, catch)
import Control.Monad (forM, forM_, forever, unless, when)
import qualified Data.ByteString.Char8 as BSC
import Data.List (nub, (\\))
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime (..))
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.UUID (UUID)
import Database.PostgreSQL.Simple (Only (..))
import qualified Database.PostgreSQL.Simple as PG
import Hnvr.Core.Logging (logError, logInfo, logWarn)
import qualified Hnvr.Storage.S3 as S3
import qualified System.Environment as Env

-- | Sweep interval: 60 s (in microseconds). Much tighter than the
-- retention sweep (1 h) — tombstoned rows are user-visible state
-- ("deletion in progress") and should clear promptly.
sweepIntervalMicros :: Int
sweepIntervalMicros = 60_000000

-- | Grace period before the sweeper adopts a batch: gives the
-- just-forked worker ('forkCameraPurge') first crack at it so the two
-- don't duplicate long S3 delete walks on the happy path.
sweeperGraceSeconds :: Int
sweeperGraceSeconds = 90

-- | Default DB URL matches IHP's. Real deployments set DATABASE_URL.
defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"

-- | One purge batch: all rows sharing a (camera_id, pending_delete_at)
-- stamp — i.e. one PurgeRecordingAction click. The window is derived
-- from the rows, so a batch always maps to one contiguous recording.
data PendingBatch = PendingBatch
  { pbCameraId :: UUID,
    pbSlug :: Text,
    pbStamp :: UTCTime,
    pbFrom :: UTCTime,
    pbTo :: UTCTime,
    pbKeys :: [Text]
  }

-- | Spawn the pending-purge sweeper. Mirrors 'startRetentionSweeper':
-- exceptions in the loop body are caught so a transient PG/S3 outage
-- doesn't kill the sweep forever.
startPendingPurgeSweeper :: IO ()
startPendingPurgeSweeper = do
  _ <- async loop
  logInfo "PendingPurge: sweeper started (60s interval, 90s grace)"
  where
    loop =
      forever $ do
        sweepOnce
          `catch` \(e :: SomeException) ->
            logError ("PendingPurge: sweep failed: " <> T.pack (show e))
        threadDelay sweepIntervalMicros

-- | Fork an immediate purge of all pending batches for one camera.
-- Called by the controller right after tombstoning so the user isn't
-- waiting for the next sweeper tick. Exceptions are logged, not
-- rethrown — the sweeper will retry anyway.
forkCameraPurge :: UUID -> IO ()
forkCameraPurge cameraId = do
  _ <- async (worker `catch` \(e :: SomeException) -> logError ("PendingPurge: worker failed: " <> T.pack (show e)))
  pure ()
  where
    worker = do
      mS3 <- S3.readS3ConfigFromEnv
      case mS3 of
        Nothing -> logWarn "PendingPurge: HNVR_S3_* env not set; batch stays pending"
        Just s3cfg -> do
          dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
          bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn -> do
            batches <- listPendingBatches conn (Just cameraId) 0
            forM_ batches (purgeBatch s3cfg conn)

-- | One sweeper pass over all cameras' stale batches.
sweepOnce :: IO ()
sweepOnce = do
  mS3 <- S3.readS3ConfigFromEnv
  case mS3 of
    Nothing -> logWarn "PendingPurge: HNVR_S3_* env not set; skipping sweep"
    Just s3cfg -> do
      dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
      bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn -> do
        batches <- listPendingBatches conn Nothing sweeperGraceSeconds
        unless (null batches) $
          logInfo ("PendingPurge: resuming " <> T.pack (show (length batches)) <> " pending batch(es)")
        forM_ batches (purgeBatch s3cfg conn)

-- | Find pending batches. @graceSeconds@ excludes batches stamped
-- within the last N seconds; @mCamera@ restricts to one camera (the
-- immediate worker path). Window + keys come from the rows themselves,
-- so a crashed worker needs no external state to resume.
listPendingBatches :: PG.Connection -> Maybe UUID -> Int -> IO [PendingBatch]
listPendingBatches conn mCamera graceSeconds = do
  heads <- case mCamera of
    Just cid ->
      PG.query
        conn
        "SELECT s.camera_id, c.slug, s.pending_delete_at, \
        \       MIN(s.start_ts), MAX(s.end_ts) \
        \ FROM segments s JOIN cameras c ON c.id = s.camera_id \
        \ WHERE s.pending_delete_at IS NOT NULL \
        \   AND s.pending_delete_at < NOW() - (? * INTERVAL '1 second') \
        \   AND s.camera_id = ? \
        \ GROUP BY s.camera_id, c.slug, s.pending_delete_at"
        (graceSeconds, cid)
    Nothing ->
      PG.query
        conn
        "SELECT s.camera_id, c.slug, s.pending_delete_at, \
        \       MIN(s.start_ts), MAX(s.end_ts) \
        \ FROM segments s JOIN cameras c ON c.id = s.camera_id \
        \ WHERE s.pending_delete_at IS NOT NULL \
        \   AND s.pending_delete_at < NOW() - (? * INTERVAL '1 second') \
        \ GROUP BY s.camera_id, c.slug, s.pending_delete_at"
        (Only graceSeconds)
  forM heads $ \(cid, slug, stamp, from, to) -> do
    keys <-
      PG.query
        conn
        "SELECT object_key FROM segments \
        \ WHERE camera_id = ? AND pending_delete_at = ?"
        (cid, stamp)
    pure
      PendingBatch
        { pbCameraId = cid,
          pbSlug = slug,
          pbStamp = stamp,
          pbFrom = from,
          pbTo = to,
          pbKeys = map fromOnly keys
        }

-- | Purge one batch: S3 deletes, then verification, then (only on a
-- verified-empty window) the hard row DELETE.
purgeBatch :: S3.S3Config -> PG.Connection -> PendingBatch -> IO ()
purgeBatch s3cfg conn PendingBatch {..} = do
  let ci = S3.connectInfo s3cfg
      bucket = S3.s3cBucket s3cfg
  -- Protect set: object keys of LIVE (non-tombstoned) rows overlapping
  -- the window. Two quick successive deletes on the same camera can
  -- merge windows via the min/max derivation; the protect set keeps
  -- the orphan pass from touching the other recording's objects.
  protectRows <-
    PG.query
      conn
      "SELECT object_key FROM segments \
      \ WHERE camera_id = ? AND end_ts > ? AND start_ts <= ? \
      \   AND pending_delete_at IS NULL"
      (pbCameraId, pbFrom, pbTo)
  let protect = map fromOnly protectRows
  -- 1. Delete row keys + orphans (day-prefix listing, timestamp in
  --    window — catches legacy second-precision keys whose DB rows
  --    are long gone), minus the protect set. Per-key failures are
  --    swallowed: verification below decides whether we're done.
  orphans <- listWindowOrphans s3cfg pbSlug pbFrom pbTo (protect <> pbKeys)
  let keys = nub (pbKeys <> orphans) \\ protect
  forM_ keys $ \k ->
    S3.deleteObject ci bucket k
      `catch` \(_ :: SomeException) -> pure ()
  -- 2. Verify: re-list the window. Anything left that isn't protected
  --    is a delete that failed — keep the rows, retry next sweep.
  remaining <- listWindowOrphans s3cfg pbSlug pbFrom pbTo protect
  if null remaining
    then do
      n <-
        PG.execute
          conn
          "DELETE FROM segments WHERE camera_id = ? AND pending_delete_at = ?"
          (pbCameraId, pbStamp)
      logInfo
        ( "PendingPurge: "
            <> pbSlug
            <> " batch verified empty; deleted "
            <> T.pack (show n)
            <> " row(s), "
            <> T.pack (show (length keys))
            <> " S3 object(s)"
        )
    else
      logWarn
        ( "PendingPurge: "
            <> pbSlug
            <> " window still has "
            <> T.pack (show (length remaining))
            <> " object(s); rows stay pending, will retry"
        )

-- | List objects under the per-day prefixes covering @[from, to]@
-- whose key-embedded timestamp falls inside the window, minus the
-- exclusion set. Used for both orphan detection and post-delete
-- verification.
listWindowOrphans ::
  S3.S3Config ->
  Text ->
  UTCTime ->
  UTCTime ->
  [Text] ->
  IO [Text]
listWindowOrphans s3cfg slug from to exclude = do
  let ci = S3.connectInfo s3cfg
      bucket = S3.s3cBucket s3cfg
      days = enumFromTo (utctDay from) (utctDay to)
  listed <- fmap concat $ forM days $ \d ->
    S3.listObjectKeys ci bucket (slug <> "/" <> T.pack (show d) <> "/")
      `catch` \(_ :: SomeException) -> pure []
  pure
    [ k
    | k <- listed,
      k `notElem` exclude,
      Just ts <- [parseKeyTimestamp slug k],
      ts >= from && ts <= to
    ]

-- | Extract the capture timestamp from an object key
-- (@slug/2026-08-11/15-02-55[.442].mp4@). Returns Nothing for keys
-- that don't match the segment layout (e.g. @init.mp4@ — never
-- purged; future playlists still need it).
parseKeyTimestamp :: Text -> Text -> Maybe UTCTime
parseKeyTimestamp slug key = do
  rest <- T.stripPrefix (slug <> "/") key
  body <- T.stripSuffix ".mp4" rest
  let s = T.unpack body
  parseTimeM True defaultTimeLocale "%Y-%m-%d/%H-%M-%S%Q" s
    <|> parseTimeM True defaultTimeLocale "%Y-%m-%d/%H-%M-%S" s
