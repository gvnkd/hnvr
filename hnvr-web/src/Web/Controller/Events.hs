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
import Data.Aeson (Value)
import qualified Data.ByteString.Char8 as BSC
import Data.Int (Int32)
import Data.Maybe (fromMaybe, isNothing)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Database.PostgreSQL.Simple as PG
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (PGArray (..), (:.) (..))
import Generated.Types
import Hnvr.Core.ArchiveBrowser (parseWhen)
import Hnvr.Core.Authz (CameraAction (..), PageKind (..))
import qualified Hnvr.Storage.S3 as S3
import Hnvr.Web.Auth ()
import Hnvr.Web.Authz (aclCameraIds, aclFilterCameras, ensurePagePerm, ensurePerm, toCameraId)
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
    ensurePagePerm PageEvents
    -- The dropdown AND the rows are scoped to the subject's
    -- view_archive ACL (events are historical camera data;
    -- design_docs/13 — filter in SQL, never post-filter).
    mAclIds <- aclCameraIds ViewArchive
    cameras <- aclFilterCameras ViewArchive (query @Camera |> orderBy #slug) >>= fetch
    let fltCamera = nonemptyParam "cameraId"
        fltKind = nonemptyParam "kind"
        fltFrom = nonemptyParam "from"
        fltTo = nonemptyParam "to"
        page = max 1 (fromMaybe 1 (nonemptyParam "page" >>= readMaybe . T.unpack))
    rows <-
      fetchEventRows
        mAclIds
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
    ensurePerm ViewArchive (toCameraId liveCameraId)
    rows <- fetchEventRows (Just [camUuid]) (Just camUuid) Nothing Nothing Nothing 1
    render FeedView {events = take 10 rows}

-- | Page rows: LIMIT pageSize+1 so a full overflow row tells us
-- whether a next page exists (no COUNT round-trip). One-shot
-- postgresql-simple connection (like SnapshotResponder) — IHP's
-- hasql-based sqlQuery has no FromRow instance for 10-tuples.
--
-- @mAclIds@ scopes rows to the subject's view_archive cameras
-- ('Hnvr.Web.Authz.aclCameraIds'); 'Nothing' = unrestricted.
fetchEventRows ::
  Maybe [UUID] ->
  Maybe UUID ->
  Maybe Text ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  Int ->
  IO [EventRow]
fetchEventRows mAclIds mCam mKind mFrom mTo page = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  rows <-
    bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn ->
      PG.query
        conn
        "SELECT e.id, e.ts, e.kind::text, e.class_id, e.track_id, \
        \       e.confidence, e.thumbnail_key, c.slug, c.id, r.name, \
        \       (SELECT ec.id FROM event_clip_events ce \
        \         JOIN event_clips ec ON ec.id = ce.clip_id \
        \        WHERE ce.event_id = e.id AND ec.pending_delete_at IS NULL \
        \        LIMIT 1), \
        \       e.host_id, e.bbox, e.segment_ts \
        \FROM events e \
        \JOIN cameras c ON c.id = e.camera_id \
        \LEFT JOIN rules r ON r.id = e.rule_id \
        \WHERE (?::uuid IS NULL OR e.camera_id = ?) \
        \  AND (?::text IS NULL OR e.kind::text = ?) \
        \  AND (?::timestamptz IS NULL OR e.ts >= ?) \
        \  AND (?::timestamptz IS NULL OR e.ts <= ?) \
        \  AND (?::bool OR e.camera_id = ANY(?::uuid[])) \
        \ORDER BY e.ts DESC \
        \LIMIT ? OFFSET ?"
        -- pg-simple caps tuple ToRow at 10 (pitfall #122) — chunk into
        -- 4-tuples joined by ':.'.
        ( (mCam, mCam, mKind, mKind)
            :. (mFrom, mFrom, mTo, mTo)
            :. ( isNothing mAclIds,
                 PGArray (fromMaybe [] mAclIds),
                 pageSize + 1,
                 (page - 1) * pageSize
               )
        )
  pure (map toRow rows)
  where
    toRow (EventRowQ eid ts kind classId trackId conf thumb slug camUuid ruleName clipId hostId bbox segmentTs) =
      EventRow
        { erId = eid,
          erTs = ts,
          erKind = kind,
          erClassId = fromIntegral <$> classId,
          erTrackId = fromIntegral <$> trackId,
          erConfidence = realToFrac <$> conf,
          erThumbnailKey = thumb,
          erCameraSlug = slug,
          erCameraUuid = camUuid,
          erRuleName = ruleName,
          erClipId = clipId,
          erHostId = hostId,
          erBbox = bbox,
          erSegmentTs = segmentTs
        }

-- | Raw query row for 'fetchEventRows'. Exceeds postgresql-simple's
-- tuple 'FromRow' instances, so we decode field by field.
data EventRowQ
  = EventRowQ
      !UUID
      !UTCTime
      !Text
      !(Maybe Int32)
      !(Maybe Int32)
      !(Maybe Float)
      !(Maybe Text)
      !Text
      !UUID
      !(Maybe Text)
      !(Maybe UUID)
      !(Maybe Text)
      !(Maybe Value)
      !(Maybe UTCTime)

instance FromRow EventRowQ where
  fromRow =
    EventRowQ
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"

-- | Presign each row's thumbnail (1 h). Rows without a key get
-- 'Nothing'; upload failures degrade to a placeholder in the view.
presignThumbs :: [EventRow] -> IO [Maybe Text]
presignThumbs rows = do
  mS3 <- liftIO S3.readS3Config
  case mS3 of
    Nothing -> pure (map (const Nothing) rows)
    Just cfg -> do
      forM rows $ \r -> case r.erThumbnailKey of
        Nothing -> pure Nothing
        Just key -> do
          url <- liftIO (S3.presignGetUrlWithConfig cfg (S3.s3cBucket cfg) key 3600)
          pure (Just (cs url))

-- | Read an optional query param as 'Nothing' when absent or empty.
nonemptyParam :: (?request :: Request) => ByteString -> Maybe Text
nonemptyParam name =
  case paramOrNothing name of
    Just t | not (T.null t) -> Just t
    _ -> Nothing
