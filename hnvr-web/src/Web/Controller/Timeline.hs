{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /Timeline — unified multi-camera archive timeline
-- (design_docs/12-timeline-archive.md, Phase B).
--
--   * 'TimelineAction' — HTML shell: camera tile grid + canvas
--     timeline. Default window = last 24 h; deep-linkable via
--     @?from=&to=&t=@ (ISO 8601 or datetime-local, parsed UTC via
--     'parseWhen' — same contract as the archive browser).
--   * 'TimelineDataAction' — JSON for the canvas: per-camera merged
--     coverage spans + bucketed event markers (pure logic in
--     'Hnvr.Core.Timeline').
--   * 'TimelineThumbAction' — 302 to the presigned S3 URL of the
--     nearest @camera_snapshots@ row at-or-before @t@; 404 when the
--     row is older than 4× the camera's snapshot interval (stale =
--     the camera wasn't recording around @t@ — the tile shows its gap
--     placeholder instead).
--
-- Playback (per-camera hls.js on cursor release) is Phase C; this
-- phase is the read path only.
module Web.Controller.Timeline
  ( TimelineController (..),
  )
where

import Control.Exception (bracket)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Database.PostgreSQL.Simple as PG
import Database.PostgreSQL.Simple.Types (PGArray (..))
import Generated.Types
import Hnvr.Core.ArchiveBrowser (parseWhen)
import Hnvr.Core.Authz (CameraAction (..), PageKind (..))
import Hnvr.Core.Recording (Span (..))
import Hnvr.Core.Timeline
import qualified Hnvr.Storage.S3 as S3
import Hnvr.Web.Auth ()
import Hnvr.Web.Authz (aclCameraIds, aclFilterCameras, ensurePagePerm, ensurePerm, toCameraId)
import Hnvr.Web.View.Timeline.Index
import IHP.Controller.Response (respondAndExit)
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)
import Network.HTTP.Types (status404)
import Network.Wai (responseLBS)
import qualified System.Environment as Env

data TimelineController
  = TimelineAction
  | TimelineDataAction
  | TimelineThumbAction {cameraId :: !(Id Camera)}
  deriving stock (Eq, Show, Data)

instance AutoRoute TimelineController

-- | Gap tolerance for merging segments into coverage spans — same
-- value the archive browser uses so the two UIs agree.
splitTolerance :: NominalDiffTime
splitTolerance = 30

-- | Default timeline window (design: last 24 h).
defaultWindow :: NominalDiffTime
defaultWindow = 24 * 3600

-- | Hard cap on a custom window — protects the segments/events scans.
maxWindow :: NominalDiffTime
maxWindow = 7 * 24 * 3600

instance Controller TimelineController where
  beforeAction = ensureIsUser

  action TimelineAction = do
    ensurePagePerm PageArchive
    cameras <- aclFilterCameras ViewArchive (query @Camera |> orderByAsc #slug) >>= fetch
    (from, to) <- resolveWindow
    now <- liftIO getCurrentTime
    let mT = nonemptyParam "t" >>= parseWhen
        cursor = maybe to (min to . max from) mT
    render IndexView {cameras, winFrom = from, winTo = to, cursor, winNow = now}
  action TimelineDataAction = do
    ensurePagePerm PageArchive
    (from, to) <- resolveWindow
    -- The JSON feed leaks as much as the shell: cameras, coverage
    -- spans and event markers are all scoped to the subject's
    -- view_archive ACL (design_docs/13 — filter in SQL).
    mAclIds <- aclCameraIds ViewArchive
    cameras <- aclFilterCameras ViewArchive (query @Camera |> orderByAsc #slug) >>= fetch
    segments <-
      ( case mAclIds of
          Nothing -> id
          Just ids -> filterWhereIn (#cameraId, ids)
      )
        ( query @Segment
            |> filterWhere (#pendingDeleteAt, Nothing)
            |> filterWhereGreaterThan (#endTs, from)
            |> filterWhereLessThanOrEqualTo (#startTs, to)
            |> orderByAsc #startTs
        )
        |> fetch
    events <- liftIO (fetchWindowEvents mAclIds from to)
    let spansByCam = M.fromListWith (++) [(spCameraId s, [s]) | s <- map toSpan segments]
        eventsByCam = M.fromListWith (++) [(cid, [m]) | (cid, m) <- events]
        slugOf c = c.slug
        timelines =
          [ let camId = camUuid c
                spans = M.findWithDefault [] camId spansByCam
                markers = M.findWithDefault [] camId eventsByCam
                (kept, truncated) = bucketMarkers markerCap from to markers
             in CameraTimeline
                  { ctId = camId,
                    ctSlug = slugOf c,
                    ctSpans = coverageSpans splitTolerance spans,
                    ctEvents = kept,
                    ctTruncated = truncated
                  }
          | c <- cameras
          ]
    renderJson TimelineResponse {trFrom = from, trTo = to, trCameras = timelines}
  action TimelineThumbAction {cameraId} = do
    ensurePerm ViewArchive (toCameraId cameraId)
    camera <- fetch cameraId
    case nonemptyParam "t" >>= parseWhen of
      Nothing -> notFound "missing or invalid t"
      Just t -> do
        now <- liftIO getCurrentTime
        let tClamped = min t now
            interval = camera.snapshotIntervalSec
        if interval <= 0
          then notFound "snapshots disabled for this camera"
          else do
            mSnap <-
              query @CameraSnapshot
                |> filterWhere (#cameraId, camUuid camera)
                |> filterWhereLessThanOrEqualTo (#ts, tClamped)
                |> orderByDesc #ts
                |> limit 1
                |> fetchOneOrNothing
            case mSnap of
              Just snap
                | diffUTCTime tClamped snap.ts <= fromIntegral (4 * interval) -> do
                    mCfg <- liftIO S3.readS3Config
                    case mCfg of
                      Nothing -> notFound "S3 not configured"
                      Just cfg -> do
                        url <- liftIO (S3.presignGetUrlWithConfig cfg (S3.s3cBucket cfg) snap.objectKey 3600)
                        redirectToUrl (cs url)
              _ -> notFound "no snapshot near t"
    where
      notFound msg =
        respondAndExit (responseLBS status404 [("Content-Type", "text/plain; charset=utf-8")] (cs (msg :: Text)))

-- ---- window resolution ----------------------------------------------

-- | from/to query params (ISO or datetime-local, UTC) with the 24 h
-- default ending at now; inverted or over-wide windows are clamped.
resolveWindow :: (?request :: Request) => IO (UTCTime, UTCTime)
resolveWindow = do
  now <- liftIO getCurrentTime
  let mFrom = nonemptyParam "from" >>= parseWhen
      mTo = nonemptyParam "to" >>= parseWhen
      to = maybe now (min now) mTo
      from0 = fromMaybe (addUTCTime (-defaultWindow) to) mFrom
      from = max (addUTCTime (-maxWindow) to) (min (addUTCTime (-60) to) from0)
  pure (from, to)

-- ---- events query -----------------------------------------------------

-- | Events in the window across ACL-visible cameras as (camera_id,
-- marker) pairs, ascending by ts (bucketMarkers expects ascending).
-- 6-tuple — inside pg-simple's tuple instances, no hand-written FromRow
-- needed. One-shot connection per pitfall #122 pattern.
--
-- @mAclIds@: 'Nothing' = unrestricted subject (is_admin fallback /
-- disabled gate / full wildcard), @Just ids@ = the camera whitelist
-- from 'Hnvr.Web.Authz.aclCameraIds' (@Just []@ returns no rows).
fetchWindowEvents :: Maybe [UUID] -> UTCTime -> UTCTime -> IO [(UUID, TimelineMarker)]
fetchWindowEvents mAclIds from to = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  rows <-
    bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn ->
      PG.query
        conn
        "SELECT e.id, e.ts, e.kind::text, e.camera_id, r.name, \
        \       (SELECT ec.id FROM event_clip_events ce \
        \         JOIN event_clips ec ON ec.id = ce.clip_id \
        \        WHERE ce.event_id = e.id AND ec.pending_delete_at IS NULL \
        \        LIMIT 1) \
        \FROM events e \
        \LEFT JOIN rules r ON r.id = e.rule_id \
        \WHERE e.ts >= ? AND e.ts <= ? \
        \  AND (?::bool OR e.camera_id = ANY(?::uuid[])) \
        \ORDER BY e.ts ASC"
        (from, to, isNothing mAclIds, PGArray (fromMaybe [] mAclIds))
  pure
    [ ( camId,
        TimelineMarker
          { tmId = eid,
            tmTs = ts,
            tmKind = kind,
            tmRule = ruleName,
            tmClipId = clipId
          }
      )
    | (eid, ts, kind, camId, ruleName, clipId) <- rows
    ]
  where
    defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"

-- ---- helpers ----------------------------------------------------------

toSpan :: Segment -> Span
toSpan s =
  Span
    { spCameraId = s.cameraId,
      spStart = s.startTs,
      spEnd = s.endTs,
      spBytes = fromIntegral s.bytes,
      spHasAudio = s.hasAudio,
      spObjectKey = s.objectKey,
      spHostId = s.hostId,
      spSha256 = s.sha256
    }

-- | hlint misparses @c.id@ (OverloadedRecordDot) as composition with
-- 'id' — go through @get #id@ (pitfall #120).
camUuid :: Camera -> UUID
camUuid c = case c |> get #id of Id u -> u

-- | Optional query param; empty/whitespace treated as absent.
nonemptyParam :: (?request :: Request) => ByteString -> Maybe Text
nonemptyParam name =
  case paramOrNothing name of
    Just t | not (T.null (T.strip t)) -> Just (T.strip t)
    _ -> Nothing
