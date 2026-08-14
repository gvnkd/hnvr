{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /Stats — storage + event statistics (Phase 4). Aggregates from
-- the @segments@/@events@/@rules@ tables; one-shot pg-simple
-- connection (same pattern as 'Web.Controller.Events.fetchEventRows').
module Web.Controller.Stats
  ( StatsController (..),
  )
where

import Control.Exception (bracket)
import qualified Data.ByteString.Char8 as BSC
import Data.Maybe (fromMaybe)
import qualified Database.PostgreSQL.Simple as PG
import Generated.Types
import Hnvr.Web.View.Stats.Index
import IHP.ControllerPrelude
import qualified System.Environment as Env

data StatsController
  = StatsAction
  deriving stock (Eq, Show, Data)

instance AutoRoute StatsController

instance Controller StatsController where
  action StatsAction = do
    stats <- liftIO fetchStats
    render IndexView {..}

fetchStats :: IO Stats
fetchStats = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn -> do
    storageRows <-
      PG.query_
        conn
        "SELECT c.slug, COALESCE(SUM(s.bytes), 0)::bigint, COUNT(s.id)::bigint \
        \FROM cameras c LEFT JOIN segments s ON s.camera_id = c.id \
        \GROUP BY c.slug ORDER BY c.slug"
    (eventsTotal, events24h) <-
      headDef (0, 0)
        <$> PG.query_
          conn
          "SELECT COUNT(*)::bigint, \
          \COUNT(*) FILTER (WHERE ts >= now() - interval '24 hours')::bigint \
          \FROM events"
    kindRows <-
      PG.query_
        conn
        "SELECT kind::text, COUNT(*)::bigint FROM events \
        \WHERE ts >= now() - interval '24 hours' \
        \GROUP BY kind ORDER BY 2 DESC"
    camEventRows <-
      PG.query_
        conn
        "SELECT c.slug, COUNT(e.id)::bigint \
        \FROM cameras c LEFT JOIN events e ON e.camera_id = c.id \
        \  AND e.ts >= now() - interval '24 hours' \
        \GROUP BY c.slug ORDER BY 2 DESC"
    rulesEnabled <-
      onlyDef 0
        <$> PG.query_ conn "SELECT COUNT(*)::bigint FROM rules WHERE enabled"
    pure
      Stats
        { stStorageByCam = storageRows,
          stEventsTotal = eventsTotal,
          stEvents24h = events24h,
          stEvents24hByKind = kindRows,
          stEvents24hByCam = camEventRows,
          stRulesEnabled = rulesEnabled
        }
  where
    headDef d = fromMaybe d . safeHead
    onlyDef d = maybe d PG.fromOnly . safeHead
    safeHead [] = Nothing
    safeHead (x : _) = Just x

defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"
