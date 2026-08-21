{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Leader-side RetentionSweeper.
--
-- Runs hourly (default) to enforce the per-camera @retention_hours@
-- cutoff. Uses the @segments@ table as the source of truth: queries
-- rows older than @NOW() - retention_hours * INTERVAL '1 hour'@, deletes
-- their @object_key@s from S3, then deletes the rows.
--
-- Trust-the-DB approach (vs S3-list-and-filter): simpler, no paginated
-- listing, no orphan-key detection. Orphan objects (uploaded without
-- a DB row, e.g. EventWriter failure mid-publish) are NOT swept —
-- they accumulate until manual cleanup. Acceptable for v1; Phase 6
-- operational hardening can add a periodic S3-list reconciliation
-- pass if orphans become a problem.
--
-- The sweep is idempotent: safe to kill mid-run, safe to re-run. If
-- the leader dies after deleting S3 objects but before deleting the
-- rows, the next sweep redoes the row delete (S3 delete of already-
-- deleted keys is a no-op).
module Hnvr.Web.RetentionSweeper
  ( startRetentionSweeper,
    sweepOnce,
    sweepEventClips,
    sweepCameraSnapshots,
    purgeClipObjects,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Exception (SomeException, bracket, catch, try)
import Control.Monad (forM, forM_, forever, unless, void, when)
import qualified Data.ByteString.Char8 as BSC
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import Database.PostgreSQL.Simple (Only (..))
import qualified Database.PostgreSQL.Simple as PG
import Hnvr.Core.Logging (logError, logInfo, logWarn)
import qualified Hnvr.Storage.S3 as S3
import qualified System.Environment as Env

-- | Sweep interval: 1 hour (in microseconds).
sweepIntervalMicros :: Int
sweepIntervalMicros = 3600_000000

-- | Default DB URL matches IHP's. Real deployments set DATABASE_URL.
defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"

-- | Spawn the retention sweeper in a background 'async'. Catches all
-- exceptions in the loop body so a transient PG/S3 outage doesn't kill
-- the sweep forever — next tick retries.
startRetentionSweeper :: IO ()
startRetentionSweeper = do
  _ <- async loop
  logInfo "RetentionSweeper: started (1h interval)"
  where
    loop =
      forever $ do
        sweepOnce
          `catch` \(e :: SomeException) ->
            logError ("RetentionSweeper: sweep failed: " <> T.pack (show e))
        threadDelay sweepIntervalMicros

-- | One sweep pass. Iterates all enabled cameras, deletes their
-- out-of-retention S3 objects + segments rows. No-op (logged) when S3
-- config is missing or no DB connection.
sweepOnce :: IO ()
sweepOnce = do
  mS3 <- S3.readS3Config
  case mS3 of
    Nothing -> logWarn "RetentionSweeper: S3 config missing (hnvr.yaml + HNVR_S3_*); skipping sweep"
    Just s3cfg -> do
      dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
      bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn -> do
        cams <-
          PG.query_
            conn
            "SELECT id, slug, retention_hours FROM cameras WHERE enabled ORDER BY slug"
        unless (null cams) $
          logInfo ("RetentionSweeper: sweeping " <> T.pack (show (length cams)) <> " camera(s)")
        forM_ cams (sweepCamera s3cfg conn)
        sweepEventClips s3cfg conn
        sweepCameraSnapshots s3cfg conn

-- | Sweep expired event clips (separated event video store) and resume
-- stale UI-tombstoned clips (90 s grace, same pattern as PendingPurge).
-- Each row carries its own snapshotted @retention_hours@; expiry is
-- @started_at < NOW() - retention_hours * INTERVAL '1 hour'@. Deletion
-- is prefix-scoped and exact (a clip owns every object under its
-- prefix — 'Hnvr.Core.Clip'), so unlike segments there is no orphan
-- ambiguity: list the prefix, delete what is listed, delete the row.
sweepEventClips :: S3.S3Config -> PG.Connection -> IO ()
sweepEventClips s3cfg conn = do
  clips <-
    PG.query_
      conn
      "SELECT id, object_prefix FROM event_clips \
      \ WHERE (pending_delete_at IS NULL \
      \        AND started_at < NOW() - (retention_hours * INTERVAL '1 hour')) \
      \    OR (pending_delete_at IS NOT NULL \
      \        AND pending_delete_at < NOW() - INTERVAL '90 seconds')"
  forM_ clips $ \(clipId, prefix) -> do
    failures <- purgeClipObjects s3cfg prefix
    if failures > 0
      then logWarn ("RetentionSweeper: " <> prefix <> " had failed deletes; row kept for next pass")
      else do
        n <- PG.execute conn "DELETE FROM event_clips WHERE id = ?" (Only (clipId :: UUID))
        when (n > 0) $
          logInfo ("RetentionSweeper: expired event clip " <> prefix <> " purged")

-- | Delete every S3 object under a clip prefix (best-effort per
-- object). Returns the number of FAILED deletes — callers must keep
-- the DB row when non-zero so the next pass converges. Exported for
-- the /Events purge action.
purgeClipObjects :: S3.S3Config -> Text -> IO Int
purgeClipObjects s3cfg prefix = do
  let ci = S3.connectInfo s3cfg
      bucket = S3.s3cBucket s3cfg
  objs <- S3.listObjectKeys ci bucket prefix
  fails <- forM objs $ \key -> do
    r <- try (S3.deleteObject ci bucket key)
    case r of
      Right () -> pure (0 :: Int)
      Left (e :: SomeException) -> do
        logWarn ("RetentionSweeper: clip object delete failed for " <> key <> ": " <> T.pack (show e))
        pure 1
  pure (sum fails)

-- | Sweep expired periodic camera snapshots (archive-timeline
-- thumbnail store, design_docs/12-timeline-archive.md). Same
-- trust-the-DB pattern as 'sweepCamera': rows past their camera's
-- @retention_hours@ cutoff give up their S3 keys, then the rows.
-- Snapshots have no tombstone flow (they're not user-deletable), so
-- unlike event_clips there is no pending_delete grace case.
sweepCameraSnapshots :: S3.S3Config -> PG.Connection -> IO ()
sweepCameraSnapshots s3cfg conn = do
  let ci = S3.connectInfo s3cfg
      bucket = S3.s3cBucket s3cfg
  keys <-
    PG.query_
      conn
      "SELECT cs.object_key FROM camera_snapshots cs \
      \ JOIN cameras c ON c.id = cs.camera_id \
      \ WHERE cs.ts < NOW() - (c.retention_hours * INTERVAL '1 hour')"
  forM_ keys $ \(Only key) ->
    S3.deleteObject ci bucket key
      `catch` \(e :: SomeException) ->
        logWarn
          ( "RetentionSweeper: S3 delete failed for "
              <> key
              <> ": "
              <> T.pack (show e)
          )
  n <-
    PG.execute_
      conn
      "DELETE FROM camera_snapshots cs USING cameras c \
      \ WHERE cs.camera_id = c.id \
      \   AND cs.ts < NOW() - (c.retention_hours * INTERVAL '1 hour')"
  when (n > 0) $
    logInfo
      ( "RetentionSweeper: deleted "
          <> T.pack (show n)
          <> " camera snapshot(s) + "
          <> T.pack (show (length keys))
          <> " S3 object(s)"
      )

-- | Sweep one camera. Both queries use the same cutoff expression
-- (@NOW() - retention_hours * INTERVAL '1 hour'@) so the S3 keys
-- returned and the rows deleted are guaranteed to match — even if
-- time advances mid-call (PG evaluates NOW() per query but the
-- difference is sub-second and the cutoff is hours in the past).
sweepCamera ::
  S3.S3Config ->
  PG.Connection ->
  (UUID, Text, Int) ->
  IO ()
sweepCamera s3cfg conn (cid, slug, retentionHours) = do
  let ci = S3.connectInfo s3cfg
      bucket = S3.s3cBucket s3cfg
  -- 1. Collect object_keys older than cutoff. Tombstoned rows
  --    (pending_delete_at, migration 0006) are PendingPurge's job —
  --    skip them here so the two sweepers don't double-walk S3.
  keys <-
    PG.query
      conn
      "SELECT object_key FROM segments \
      \ WHERE camera_id = ? \
      \   AND end_ts < NOW() - (? * INTERVAL '1 hour') \
      \   AND pending_delete_at IS NULL"
      (cid, retentionHours)
  -- 2. Delete each from S3 (best-effort — log per-key failures but
  -- don't abort the sweep; the next pass retries).
  forM_ keys $ \(Only key) ->
    S3.deleteObject ci bucket key
      `catch` \(e :: SomeException) ->
        logWarn
          ( "RetentionSweeper: S3 delete failed for "
              <> key
              <> ": "
              <> T.pack (show e)
          )
  -- 3. Delete the segments rows (same tombstone skip as step 1).
  n <-
    PG.execute
      conn
      "DELETE FROM segments \
      \ WHERE camera_id = ? \
      \   AND end_ts < NOW() - (? * INTERVAL '1 hour') \
      \   AND pending_delete_at IS NULL"
      (cid, retentionHours)
  when (n > 0) $
    logInfo
      ( "RetentionSweeper: "
          <> slug
          <> " deleted "
          <> T.pack (show n)
          <> " segment(s) + "
          <> T.pack (show (length keys))
          <> " S3 object(s) (retention="
          <> T.pack (show retentionHours)
          <> "h)"
      )
