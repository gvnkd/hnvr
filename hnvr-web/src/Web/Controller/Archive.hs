{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Archive browser + playback controller.
--
--   * 'ArchiveAction' — recording browser: filter by camera, time window,
--     minimum duration, and slug search; paginated table of recordings
--     (segments grouped via 'Hnvr.Core.Recording.groupRecordings').
--   * 'PlayerArchiveAction' — HTML page with @\<video\>@ + hls.js; plays
--     the window handed to 'PlaylistArchiveAction' (deep-linkable via
--     @?from=…&to=…@, auto-seek via @?t=…@).
--   * 'PlaylistArchiveAction' — VOD m3u8 with presigned S3 GET URLs for
--     the segments overlapping the requested window (design 05 §Archive
--     playback: window validated ≤ 6 h; default = most recent 1 h).
--   * 'PurgeRecordingAction' — admin-only; tombstones the window's
--     segment rows (@pending_delete_at@, migration 0006) so they vanish
--     from every read path immediately, then forks
--     'Hnvr.Web.PendingPurge.forkCameraPurge': S3 objects are deleted,
--     the window is verified empty, and only then are the rows hard-
--     DELETEd. Named "Purge", not "Delete": AutoRoute maps @Delete*@
--     constructors to HTTP DELETE only, and our plain POST forms don't
--     load ihp.js's method-override helper (AssignCameraAction uses the
--     same unprefixed-name POST pattern).
--
-- Optional query params are read via 'paramOrNothing' — AutoRoute only
-- sees the @cameraId@ field.
module Web.Controller.Archive
  ( ArchiveController (..),
  )
where

import Data.List (nub)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Ord (Down (..))
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, UTCTime (..), addUTCTime, diffUTCTime, getCurrentTime)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Generated.Types
import Hnvr.Core.ArchiveBrowser
  ( BrowseNotice (..),
    Page (..),
    browseQueryString,
    parseWhen,
    resolveBrowseWindow,
  )
import qualified Hnvr.Core.ArchiveBrowser as AB
import Hnvr.Core.Playlist (renderEmptyPlaylist, renderVodPlaylist)
import Hnvr.Core.Recording (Recording (..), Span (..), groupRecordings, recGaps)
import qualified Hnvr.Storage.S3 as S3
import Hnvr.Web.Auth ()
import Hnvr.Web.PendingPurge (forkCameraPurge)
import Hnvr.Web.View.Archive.Index
import Hnvr.Web.View.Archive.Player
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (currentUserOrNothing, ensureIsUser)
import Text.Read (readMaybe)

data ArchiveController
  = ArchiveAction
  | PlayerArchiveAction {cameraId :: !(Id Camera)}
  | PlaylistArchiveAction {cameraId :: !(Id Camera)}
  | -- | Why @purgeCameraId@ and not @cameraId@: IHP AutoRoute generates
    -- the URL @/PurgeRecording?cameraId=…@ from the field name. The
    -- archive browser also round-trips a 'cameraId' FILTER param via
    -- the same URL so the post-delete redirect can land back on the
    -- same filtered view (see 'browseQueryString' + 'returnTo'). With
    -- both names colliding we got @?cameraId=X&cameraId=X@ — Sergey
    -- caught this in DevTools on 2026-08-12. Renaming the action field
    -- to @purgeCameraId@ gives the filter's @cameraId@ its own slot
    -- and the URL reads @/PurgeRecording?purgeCameraId=X&cameraId=Y@.
    PurgeRecordingAction {purgeCameraId :: !(Id Camera)}
  deriving stock (Eq, Show, Data)

instance AutoRoute ArchiveController

-- | Gap between consecutive segments that splits one recording into two.
splitTolerance :: NominalDiffTime
splitTolerance = 30

-- | Hole threshold surfaced inside a recording (badge "N gaps").
gapMin :: NominalDiffTime
gapMin = 1.5

-- | Page size for the @/Archive@ recordings table. Smaller than the
-- IHP-norm so a full day of recordings on a busy camera grid actually
-- pages — 25 was too generous (any single-camera 24 h window almost
-- always fit on one page, so the "1/1" pagination looked broken).
pageSize :: Int
pageSize = 10

instance Controller ArchiveController where
  beforeAction = ensureIsUser

  action ArchiveAction = do
    let fltCamera = nonemptyParam "cameraId"
        fltFrom = nonemptyParam "from"
        fltTo = nonemptyParam "to"
        fltQ = nonemptyParam "q"
        fltMinDur = nonemptyParam "minDuration" >>= readMaybe . T.unpack
        pageRequested = max 1 (fromMaybe 1 (nonemptyParam "page" >>= readMaybe . T.unpack))

    cameras <- query @Camera |> orderByAsc #slug |> fetch
    let slugMap = M.fromList [(camUuid c, c.slug) | c <- cameras]

    now <- liftIO getCurrentTime
    let (mFrom, mTo, notice) = case resolveBrowseWindow now (fltFrom >>= parseWhen) (fltTo >>= parseWhen) of
          (f, t, n) -> (f, t, noticeText n)
        -- Search: resolve matching camera ids first (no joins in the
        -- query builder), then constrain segments by id set.
        mSelectedCam = fltCamera >>= UUID.fromText
        matchingCamIds =
          case (mSelectedCam, fltQ) of
            (Just cid, _) -> Just [cid]
            (Nothing, Just q) ->
              Just [camUuid c | c <- cameras, q `T.isInfixOf` T.toLower c.slug]
            (Nothing, Nothing) -> Nothing

    segments <- case matchingCamIds of
      Just [] -> pure [] -- search matched no camera
      _ -> do
        -- Tombstoned rows (pending verified S3 purge) are hidden from
        -- the browser — the recording is "deleted" from the user's
        -- point of view the moment the stamp lands.
        let q0 = query @Segment |> filterWhere (#pendingDeleteAt, Nothing) |> orderByAsc #startTs
            q1 = maybe q0 (\f -> q0 |> filterWhereGreaterThan (#endTs, f)) mFrom
            q2 = maybe q1 (\t -> q1 |> filterWhereLessThanOrEqualTo (#startTs, t)) mTo
            q3 = maybe q2 (\ids -> q2 |> filterWhereIn (#cameraId, ids)) matchingCamIds
        fetch q3

    let spans = map toSpan segments
        recs0 = groupRecordings splitTolerance spans
        recs1 =
          maybe
            recs0
            (\m -> filter (\r -> diffUTCTime (recEnd r) (recStart r) >= fromIntegral m) recs0)
            fltMinDur
        recs = sortOn (Down . recStart) recs1
        pg = AB.paginate pageSize pageRequested recs
        rows = map (toRow slugMap) (pageItems pg)
        isAdmin = maybe False (.isAdmin) (currentUserOrNothing @User)
        queryString = browseQueryString fltCamera fltFrom fltTo fltQ fltMinDur
        totalPages = pageTotal pg
        page = pageNumber pg
        total = pageItemTotal pg
    render IndexView {..}
    where
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
      toRow slugs r =
        let camUuid = case recSpans r of
              (s : _) -> spCameraId s
              [] -> UUID.nil
         in RecordingRow
              { rrCameraId = UUID.toText camUuid,
                rrCameraSlug = M.findWithDefault "?" camUuid slugs,
                rrStart = recStart r,
                rrEnd = recEnd r,
                rrSegments = length (recSpans r),
                rrBytes = sum (map spBytes (recSpans r)),
                rrHasAudio = any spHasAudio (recSpans r),
                rrGapCount = length (recGaps gapMin r),
                rrHosts = nub (mapMaybe spHostId (recSpans r)),
                rrFirstSha = case recSpans r of
                  (s : _) -> spSha256 s
                  [] -> ""
              }
  action PlayerArchiveAction {cameraId} = do
    camera <- fetch cameraId
    let mFrom = nonemptyParam "from"
        mTo = nonemptyParam "to"
        mT = nonemptyParam "t"
        startOffset = do
          from <- mFrom >>= parseWhen
          t <- mT >>= parseWhen
          let off = floor (diffUTCTime t from) :: Int
          if off > 0 then Just off else Nothing
    render PlayerView {..}
  action PlaylistArchiveAction {cameraId} = do
    camera <- fetch cameraId
    let cameraUuid = case cameraId of Id u -> u :: UUID
        mFrom = nonemptyParam "from"
        mTo = nonemptyParam "to"
    window <- resolvePlaylistWindow cameraUuid (mFrom >>= parseWhen) (mTo >>= parseWhen)
    case window of
      Left err -> do
        -- No setStatus in IHP v1.6.0: 200 + text/plain body; hls.js
        -- surfaces the parse failure in the player status line.
        setHeader ("Content-Type", "text/plain; charset=utf-8")
        renderPlain (cs err :: LByteString)
      Right (from, to) -> do
        segments <-
          query @Segment
            |> filterWhere (#cameraId, cameraUuid)
            |> filterWhere (#pendingDeleteAt, Nothing)
            |> filterWhereGreaterThan (#endTs, from)
            |> filterWhereLessThanOrEqualTo (#startTs, to)
            |> orderByAsc #startTs
            |> fetch
        cfg <- liftIO readS3Config
        m3u8 <- case cfg of
          Nothing -> pure renderEmptyPlaylist
          Just c -> liftIO (buildPlaylist camera segments c)
        setHeader ("Content-Type", "application/vnd.apple.mpegurl")
        setHeader ("Cache-Control", "private, max-age=0")
        renderPlain (cs m3u8 :: LByteString)
  action PurgeRecordingAction {purgeCameraId} = do
    let isAdmin = maybe False (.isAdmin) (currentUserOrNothing @User)
        -- Read ALL filter params here so we can send the user back to
        -- the same filtered view (instead of the default window) after
        -- the destructive action lands. Without this the user lost
        -- their filter context and saw a "fresh" /Archive that often
        -- showed a different (overlapping) recording set, which read
        -- as "the deleted row is still there" — see MEMORIES for the
        -- archive-browser slice write-up.
        fltCamera = nonemptyParam "cameraId"
        fltFrom = nonemptyParam "from"
        fltTo = nonemptyParam "to"
        fltQ = nonemptyParam "q"
        fltMinDur = nonemptyParam "minDuration" >>= readMaybe . T.unpack
        fltPage = nonemptyParam "page"
        -- Build the return URL as Text (redirectToPath wants Text).
        -- Strip the leading "&" from browseQueryString (it's part of
        -- its contract — see Hnvr.Core.ArchiveBrowser) and prepend
        -- "?"; append page only when it's not the default "1".
        filterQs = T.drop 1 (browseQueryString fltCamera fltFrom fltTo fltQ fltMinDur)
        pageSuffix = case fltPage of
          Just p | p /= "1" -> "&page=" <> p
          _ -> ""
        returnTo =
          if T.null filterQs
            then case pageSuffix of
              "" -> "/Archive"
              ps -> "/Archive?" <> T.drop 1 ps -- drop leading "&"
            else "/Archive?" <> filterQs <> pageSuffix
    if not isAdmin
      then setErrorMessage "Recording deletion requires an admin user"
      else do
        case (nonemptyParam "purgeFrom" >>= parseWhen, nonemptyParam "purgeTo" >>= parseWhen) of
          (Just from, Just to) -> do
            _camera <- fetch purgeCameraId
            let cameraUuid = case purgeCameraId of Id u -> u :: UUID
            -- TOMBSTONE, don't delete (migration 0006): stamping
            -- pending_delete_at synchronously hides the recording from
            -- every read path before the redirect re-renders — the
            -- async-delete race Sergey hit on 2026-08-15 is gone by
            -- construction. The hard DELETE happens in
            -- Hnvr.Web.PendingPurge only AFTER the S3 purge is
            -- verified empty; if the leader dies mid-purge, the
            -- tombstoned rows survive and the 60s sweeper resumes the
            -- batch (the failure that orphaned 98.6k objects that
            -- same day). One UPDATE = one round-trip.
            _ <-
              sqlExec
                "UPDATE segments SET pending_delete_at = NOW() \
                \ WHERE camera_id = ? AND end_ts > ? AND start_ts <= ? \
                \   AND pending_delete_at IS NULL"
                (cameraUuid, from, to)
            liftIO (forkCameraPurge cameraUuid)
            setSuccessMessage
              "Recording hidden — DB rows are removed once S3 cleanup is verified"
          _ -> setErrorMessage "Purge requires valid from/to timestamps"
    redirectToPath returnTo

-- ---- window resolution ---------------------------------------------

-- | Hard cap for the playlist window (design 05 §Archive playback).
playlistWindowMax :: NominalDiffTime
playlistWindowMax = 6 * 3600

-- | Default playlist window when no from/to is given.
playlistWindowDefault :: NominalDiffTime
playlistWindowDefault = 3600

noticeText :: BrowseNotice -> Maybe Text
noticeText NoNotice = Nothing
noticeText (BrowseClamped msg) = Just msg

-- | Playlist window (design 05 §Archive playback): explicit from/to
-- validated to ≤ 6 h; otherwise the 1 h preceding the camera's most
-- recent segment (so a camera that stopped recording yesterday still
-- gets a playable default).
resolvePlaylistWindow ::
  (?modelContext :: ModelContext) =>
  UUID ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  IO (Either Text (UTCTime, UTCTime))
resolvePlaylistWindow cameraUuid mFrom mTo =
  case (mFrom, mTo) of
    (Just f, Just t)
      | t <= f -> pure (Left "from must be before to")
      | diffUTCTime t f > playlistWindowMax ->
          pure (Left "Playlist window is limited to 6 hours; use the export feature for longer ranges")
    (Just f, Just t) -> pure (Right (f, t))
    (Just f, Nothing) -> pure (Right (f, addUTCTime playlistWindowDefault f))
    (Nothing, Just t) -> pure (Right (addUTCTime (-playlistWindowDefault) t, t))
    (Nothing, Nothing) -> do
      latest <-
        query @Segment
          |> filterWhere (#cameraId, cameraUuid)
          |> filterWhere (#pendingDeleteAt, Nothing)
          |> orderByDesc #startTs
          |> limit 1
          |> fetchOneOrNothing
      case latest of
        Just s -> pure (Right (addUTCTime (-playlistWindowDefault) s.endTs, s.endTs))
        Nothing -> do
          now <- liftIO getCurrentTime
          pure (Right (addUTCTime (-playlistWindowDefault) now, now))

-- ---- query param + time helpers -------------------------------------

-- | Optional query param; empty/whitespace treated as absent. Pure —
-- 'paramOrNothing' reads from the request context directly.
nonemptyParam :: (?request :: Request) => ByteString -> Maybe Text
nonemptyParam name =
  case paramOrNothing name of
    Just t | not (T.null (T.strip t)) -> Just (T.strip t)
    _ -> Nothing

-- | hlint misparses @c.id@ (OverloadedRecordDot) as composition with
-- 'id' and flags it "redundant" — go through @get #id@ instead.
camUuid :: Camera -> UUID
camUuid c = case c |> get #id of Id u -> u

-- ---- playlist rendering ---------------------------------------------

-- | Build a VOD m3u8 with presigned S3 GET URLs (1-hour expiry) for each
-- segment; pure rendering lives in 'Hnvr.Core.Playlist'.
buildPlaylist :: Camera -> [Segment] -> S3.S3Config -> IO Text
buildPlaylist camera segments cfg = do
  let bucket = S3.s3cBucket cfg
      slug = camera.slug
  initUrl <- cs <$> S3.presignGetUrlWithConfig cfg bucket (slug <> "/init.mp4") 3600
  segUrls <- mapM (presignSegment cfg bucket) segments
  let entries = zipWith entry segments segUrls
  pure (renderVodPlaylist initUrl entries)
  where
    presignSegment cfg bucket seg =
      cs <$> S3.presignGetUrlWithConfig cfg bucket seg.objectKey 3600
    entry seg url = (realToFrac (diffUTCTime seg.endTs seg.startTs), url)

-- | Read S3 config from environment variables. Returns Nothing if any
-- required var is missing. Reads each request — fine for v1; a future
-- slice will cache via FrameworkConfig + sops-nix.
readS3Config :: IO (Maybe S3.S3Config)
readS3Config = S3.readS3ConfigFromEnv
