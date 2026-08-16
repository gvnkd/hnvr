{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Periodic ONVIF drift checker.
--
-- Every @HNVR_ONVIF_POLL_SECONDS@ (default 300) reads back the encoder
-- configuration of every ONVIF-managed camera (@onvif_port IS NOT NULL@,
-- @enabled@), diffs it against the sparse desired settings in the
-- cameras row ('Hnvr.Web.OnvifSync.checkCameraDrift'), and reconciles
-- the @camera_drift@ table: new/updated mismatches are upserted
-- (last_seen_at bumped), resolved rows are deleted. The /Cameras and
-- /ShowCamera views render the table as a drift badge.
--
-- A camera that fails to answer (offline, no ONVIF, auth rejected)
-- keeps its existing drift rows untouched — an unreachable camera is
-- neither drifted nor in-sync, so we don't flap the badge.
module Hnvr.Web.OnvifSyncer
  ( startOnvifSyncer,
    pollOnce,
    persistDrift,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Exception (SomeException, bracket, catch)
import Control.Monad (forM_, forever, void)
import qualified Data.ByteString.Char8 as BSC
import Data.Maybe (fromMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import qualified Database.PostgreSQL.Simple as PG
import Generated.Types
import Hnvr.Core.Logging (logError, logInfo, logWarn)
import Hnvr.Core.Onvif (DriftItem (..))
import Hnvr.Web.OnvifSync (checkCameraDrift, targetForCamera)
import IHP.Fetch (fetch)
import IHP.HaskellSupport (get, (|>))
import IHP.ModelSupport (Id' (Id), ModelContext)
import IHP.QueryBuilder (query)
import qualified Network.HTTP.Client as HC
import qualified System.Environment as Env
import Text.Read (readMaybe)

-- | Default DB URL matches IHP's. Real deployments set DATABASE_URL.
defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"

-- | Spawn the poller in a background async. One immediate pass at
-- startup, then every poll interval. Loop-body exceptions are caught so
-- a transient outage doesn't kill the poller.
startOnvifSyncer :: (?modelContext :: ModelContext) => IO ()
startOnvifSyncer = do
  secs <- fromMaybe 300 . (>>= readMaybe) <$> Env.lookupEnv "HNVR_ONVIF_POLL_SECONDS"
  _ <- async (loop secs)
  logInfo ("OnvifSyncer: started (" <> tshow secs <> "s interval)")
  where
    loop secs =
      forever $ do
        pollOnce
          `catch` \(e :: SomeException) ->
            logError ("OnvifSyncer: poll failed: " <> T.pack (show e))
        threadDelay (secs * 1000000)

-- | One drift-check pass over all ONVIF-managed enabled cameras.
pollOnce :: (?modelContext :: ModelContext) => IO ()
pollOnce = do
  mgr <- HC.newManager HC.defaultManagerSettings
  cameras <- query @Camera |> fetch
  let managed = filter (\c -> isJust c.onvifPort && c.enabled) cameras
  forM_ managed $ \cam -> do
    eTarget <- targetForCamera cam
    case eTarget of
      Left why -> logWarn ("OnvifSyncer: " <> cam.slug <> ": skipped: " <> why)
      Right target -> do
        eDrift <- checkCameraDrift mgr target cam
        case eDrift of
          Left why -> logWarn ("OnvifSyncer: " <> cam.slug <> ": unreachable: " <> why)
          Right items -> do
            let uuid = case cam |> get #id of Id u -> u
            persistDrift uuid items
            logInfo
              ( "OnvifSyncer: "
                  <> cam.slug
                  <> ": "
                  <> (if null items then "in sync" else tshow (length items) <> " drifted field(s)")
              )

-- | Reconcile @camera_drift@ for one camera: upsert current mismatches
-- (bumping last_seen_at), delete rows for fields that no longer drift.
-- Opens a one-shot pg-simple connection (IHP's Hasql pool is request-
-- scoped; this runs in background threads and POST actions alike).
persistDrift :: UUID -> [DriftItem] -> IO ()
persistDrift camUuid items = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn -> do
    forM_ items $ \d ->
      PG.execute
        conn
        "INSERT INTO camera_drift (camera_id, config_name, field_name, desired, observed)\
        \ VALUES (?, ?, ?, ?, ?)\
        \ ON CONFLICT (camera_id, config_name, field_name)\
        \ DO UPDATE SET desired = EXCLUDED.desired, observed = EXCLUDED.observed,\
        \   last_seen_at = NOW()"
        (camUuid, diConfig d, diField d, diDesired d, diObserved d)
    -- Delete rows whose (config_name, field_name) no longer drifts.
    -- pg-simple can't express a row-constructor NOT IN over tuples, so
    -- fetch existing keys and delete the stale ones individually (a
    -- handful of rows per camera at most).
    existing <-
      PG.query
        conn
        "SELECT config_name, field_name FROM camera_drift WHERE camera_id = ?"
        (PG.Only camUuid)
    let current = [(diConfig d, diField d) | d <- items]
        stale = filter (`notElem` current) existing
    forM_ stale $ \(cfg, fld) ->
      void $
        PG.execute
          conn
          "DELETE FROM camera_drift\
          \ WHERE camera_id = ? AND config_name = ? AND field_name = ?"
          (camUuid, cfg, fld)

tshow :: (Show a) => a -> Text
tshow = T.pack . show
