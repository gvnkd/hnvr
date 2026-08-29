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
import Data.Maybe (fromMaybe, isNothing)
import Data.UUID (UUID)
import qualified Database.PostgreSQL.Simple as PG
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Generated.Types
import Hnvr.Core.Authz (CameraAction (..), PageKind (..))
import Hnvr.Web.Authz (aclCameraIds, ensurePagePerm)
import Hnvr.Web.View.Stats.Index
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)
import qualified System.Environment as Env

data StatsController
  = StatsAction
  deriving stock (Eq, Show, Data)

instance AutoRoute StatsController

instance Controller StatsController where
  beforeAction = ensureIsUser
  action StatsAction = do
    -- No dedicated 'stats' page_kind (design_docs/13 enum) — the
    -- settings-class grant covers it; per-camera aggregates are scoped
    -- to the subject's view_archive ACL.
    ensurePagePerm PageSettings
    mAclIds <- aclCameraIds ViewArchive
    stats <- liftIO (fetchStats mAclIds)
    render IndexView {..}

fetchStats :: Maybe [UUID] -> IO Stats
fetchStats mAclIds = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn -> do
    storageRows <-
      PG.query
        conn
        "SELECT c.slug, COALESCE(SUM(s.bytes), 0)::bigint, COUNT(s.id)::bigint \
        \FROM cameras c LEFT JOIN segments s ON s.camera_id = c.id \
        \WHERE (?::bool OR c.id = ANY(?::uuid[])) \
        \GROUP BY c.slug ORDER BY c.slug"
        aclParams
    (eventsTotal, events24h) <-
      headDef (0, 0)
        <$> PG.query
          conn
          "SELECT COUNT(*)::bigint, \
          \COUNT(*) FILTER (WHERE ts >= now() - interval '24 hours')::bigint \
          \FROM events e WHERE (?::bool OR e.camera_id = ANY(?::uuid[]))"
          aclParams
    kindRows <-
      PG.query
        conn
        "SELECT kind::text, COUNT(*)::bigint FROM events e \
        \WHERE ts >= now() - interval '24 hours' \
        \  AND (?::bool OR e.camera_id = ANY(?::uuid[])) \
        \GROUP BY kind ORDER BY 2 DESC"
        aclParams
    camEventRows <-
      PG.query
        conn
        "SELECT c.slug, COUNT(e.id)::bigint \
        \FROM cameras c LEFT JOIN events e ON e.camera_id = c.id \
        \  AND e.ts >= now() - interval '24 hours' \
        \WHERE (?::bool OR c.id = ANY(?::uuid[])) \
        \GROUP BY c.slug ORDER BY 2 DESC"
        aclParams
    rulesEnabled <-
      onlyDef 0
        <$> PG.query
          conn
          "SELECT COUNT(*)::bigint FROM rules r \
          \WHERE r.enabled AND (?::bool OR r.camera_id = ANY(?::uuid[]))"
          aclParams
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
    aclParams = (isNothing mAclIds, PGArray (fromMaybe [] mAclIds))
    headDef d = fromMaybe d . safeHead
    onlyDef d = maybe d PG.fromOnly . safeHead
    safeHead [] = Nothing
    safeHead (x : _) = Just x

defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"
