{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Leader-side RetentionSweeper.
--
-- Runs hourly (default) to enforce the per-camera @retention_days@
-- cutoff. Uses the @segments@ table as the source of truth: queries
-- rows older than @NOW() - retention_days * INTERVAL '1 day'@, deletes
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
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Exception (SomeException, bracket, catch)
import Control.Monad (forM_, forever, void, when)
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
  mS3 <- readS3Config
  case mS3 of
    Nothing -> logWarn "RetentionSweeper: HNVR_S3_* env not set; skipping sweep"
    Just s3cfg -> do
      dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
      bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn -> do
        cams <-
          PG.query_
            conn
            "SELECT id, slug, retention_days FROM cameras WHERE enabled ORDER BY slug"
        when (not (null cams)) $
          logInfo ("RetentionSweeper: sweeping " <> T.pack (show (length cams)) <> " camera(s)")
        forM_ cams (sweepCamera s3cfg conn)

-- | Sweep one camera. Both queries use the same cutoff expression
-- (@NOW() - retention_days * INTERVAL '1 day'@) so the S3 keys
-- returned and the rows deleted are guaranteed to match — even if
-- time advances mid-call (PG evaluates NOW() per query but the
-- difference is sub-second and the cutoff is days in the past).
sweepCamera ::
  S3.S3Config ->
  PG.Connection ->
  (UUID, Text, Int) ->
  IO ()
sweepCamera s3cfg conn (cid, slug, retentionDays) = do
  let ci = S3.connectInfo s3cfg
      bucket = S3.s3cBucket s3cfg
  -- 1. Collect object_keys older than cutoff.
  keys <-
    PG.query
      conn
      "SELECT object_key FROM segments \
      \ WHERE camera_id = ? \
      \   AND end_ts < NOW() - (? * INTERVAL '1 day')"
      (cid, retentionDays)
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
  -- 3. Delete the segments rows.
  n <-
    PG.execute
      conn
      "DELETE FROM segments \
      \ WHERE camera_id = ? \
      \   AND end_ts < NOW() - (? * INTERVAL '1 day')"
      (cid, retentionDays)
  when (n > 0) $
    logInfo
      ( "RetentionSweeper: "
          <> slug
          <> " deleted "
          <> T.pack (show n)
          <> " segment(s) + "
          <> T.pack (show (length keys))
          <> " S3 object(s) (retention="
          <> T.pack (show retentionDays)
          <> "d)"
      )

-- | Same S3 config reader as the one in NodeMain / Config.hs. Duplicated
-- to keep this module standalone (no IHP import burden).
readS3Config :: IO (Maybe S3.S3Config)
readS3Config = do
  let lookupText var = fmap T.pack <$> Env.lookupEnv var
  mEndpoint <- lookupText "HNVR_S3_ENDPOINT"
  mAccessKey <- lookupText "HNVR_S3_ACCESS_KEY"
  mSecretKey <- lookupText "HNVR_S3_SECRET_KEY"
  mBucket <- lookupText "HNVR_S3_BUCKET"
  pure $ do
    endpoint <- mEndpoint
    accessKey <- mAccessKey
    secretKey <- mSecretKey
    bucket <- mBucket
    Just
      S3.S3Config
        { S3.s3cEndpoint = endpoint,
          S3.s3cAccessKey = accessKey,
          S3.s3cSecretKey = secretKey,
          S3.s3cBucket = bucket
        }
