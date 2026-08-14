{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /Events — CV event browser (Phase 4).
--
-- Filter by camera, kind, and time window; paginated (20/page).
-- Each row shows the bbox-overlay thumbnail (presigned S3 GET, 1 h)
-- and deep-links into the archive player at the event timestamp
-- (@/PlayerArchive?cameraId=…&from=…&to=…&t=…@).
module Web.Controller.Events
  ( EventsController (..),
  )
where

import Control.Exception (bracket)
import qualified Data.ByteString.Char8 as BSC
import Data.Int (Int32)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Database.PostgreSQL.Simple as PG
import Generated.Types
import Hnvr.Core.ArchiveBrowser (parseWhen)
import qualified Hnvr.Storage.S3 as S3
import Hnvr.Web.Auth ()
import Hnvr.Web.View.Events.Feed
import Hnvr.Web.View.Events.Index
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)
import qualified System.Environment as Env
import Text.Read (readMaybe)

data EventsController
  = EventsAction
  | -- | HTML fragment: last 10 events for a camera. Polled by the
    -- /live page's feed panel (IHP autoRefresh needs ihp.js, which our
    -- layout doesn't load — the page polls this instead).
    EventsFeedLiveAction {liveCameraId :: !(Id Camera)}
  deriving stock (Eq, Show, Data)

instance AutoRoute EventsController

pageSize :: Int
pageSize = 20

instance Controller EventsController where
  beforeAction = ensureIsUser

  action EventsAction = do
    cameras <- query @Camera |> orderBy #slug |> fetch
    let fltCamera = nonemptyParam "cameraId"
        fltKind = nonemptyParam "kind"
        fltFrom = nonemptyParam "from"
        fltTo = nonemptyParam "to"
        page = max 1 (fromMaybe 1 (nonemptyParam "page" >>= readMaybe . T.unpack))
    rows <-
      fetchEventRows
        (fltCamera >>= UUID.fromText)
        fltKind
        (fltFrom >>= parseWhen)
        (fltTo >>= parseWhen)
        page
    let hasNext = length rows > pageSize
        pageRows = take pageSize rows
    thumbs <- presignThumbs pageRows
    render IndexView {events = zip pageRows thumbs, ..}
  action EventsFeedLiveAction {liveCameraId} = do
    let camUuid = case liveCameraId of Id u -> u
    rows <- fetchEventRows (Just camUuid) Nothing Nothing Nothing 1
    render FeedView {events = take 10 rows}

-- | Page rows: LIMIT pageSize+1 so a full overflow row tells us
-- whether a next page exists (no COUNT round-trip). One-shot
-- postgresql-simple connection (like SnapshotResponder) — IHP's
-- hasql-based sqlQuery has no FromRow instance for 10-tuples.
fetchEventRows ::
  Maybe UUID ->
  Maybe Text ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Int ->
  IO [EventRow]
fetchEventRows mCam mKind mFrom mTo page = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  rows <-
    bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn ->
      PG.query
        conn
        "SELECT e.id, e.ts, e.kind::text, e.class_id, e.track_id, \
        \       e.confidence, e.thumbnail_key, c.slug, c.id, r.name \
        \FROM events e \
        \JOIN cameras c ON c.id = e.camera_id \
        \LEFT JOIN rules r ON r.id = e.rule_id \
        \WHERE (?::uuid IS NULL OR e.camera_id = ?) \
        \  AND (?::text IS NULL OR e.kind::text = ?) \
        \  AND (?::timestamptz IS NULL OR e.ts >= ?) \
        \  AND (?::timestamptz IS NULL OR e.ts <= ?) \
        \ORDER BY e.ts DESC \
        \LIMIT ? OFFSET ?"
        ( mCam,
          mCam,
          mKind,
          mKind,
          mFrom,
          mFrom,
          mTo,
          mTo,
          pageSize + 1,
          (page - 1) * pageSize
        )
  pure (map toRow rows)
  where
    toRow (eid, ts, kind, classId, trackId, conf, thumb, slug, camUuid, ruleName) =
      EventRow
        { erId = eid,
          erTs = ts,
          erKind = kind,
          erClassId = fromIntegral <$> (classId :: Maybe Int32),
          erTrackId = fromIntegral <$> (trackId :: Maybe Int32),
          erConfidence = realToFrac <$> (conf :: Maybe Float),
          erThumbnailKey = thumb,
          erCameraSlug = slug,
          erCameraUuid = camUuid,
          erRuleName = ruleName
        }

defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"

-- | Presign each row's thumbnail (1 h). Rows without a key get
-- 'Nothing'; upload failures degrade to a placeholder in the view.
presignThumbs :: [EventRow] -> IO [Maybe Text]
presignThumbs rows = do
  mS3 <- liftIO readS3Config
  case mS3 of
    Nothing -> pure (map (const Nothing) rows)
    Just cfg -> do
      let ci = S3.connectInfo cfg
      forM rows $ \r -> case r.erThumbnailKey of
        Nothing -> pure Nothing
        Just key -> do
          url <- liftIO (S3.presignGetUrl ci (S3.s3cBucket cfg) key 3600)
          pure (Just (cs url))

-- | Same env-based S3 config reader as Config/Archive (the duplication
-- is deliberate — see Hnvr.Web.Config.readS3Config's comment).
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

-- | Read an optional query param as 'Nothing' when absent or empty.
nonemptyParam :: (?request :: Request) => ByteString -> Maybe Text
nonemptyParam name =
  case paramOrNothing name of
    Just t | not (T.null t) -> Just t
    _ -> Nothing
