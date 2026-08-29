{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Archive playback + purge controller.
--
--   * 'PlayerArchiveAction' — HTML page with @\<video\>@ + hls.js; plays
--     the window handed to 'PlaylistArchiveAction' (deep-linkable via
--     @?from=…&to=…@, auto-seek via @?t=…@). Kept for single-camera
--     deep links; the multi-camera /Timeline page is the primary
--     archive UI since v0.14 (design_docs/12-timeline-archive.md).
--   * 'PlaylistArchiveAction' — VOD m3u8 with presigned S3 GET URLs for
--     the segments overlapping the requested window (design 05 §Archive
--     playback: window validated ≤ 6 h; default = most recent 1 h).
--     The timeline's per-camera tiles consume this directly.
--   * 'PurgeRecordingAction' — admin-only; tombstones the window's
--     segment rows (@pending_delete_at@, migration 0006) so they vanish
--     from every read path immediately, then forks
--     'Hnvr.Web.PendingPurge.forkCameraPurge': S3 objects are deleted,
--     the window is verified empty, and only then are the rows hard-
--     DELETEd. Named "Purge", not "Delete": AutoRoute maps @Delete*@
--     constructors to HTTP DELETE only, and our plain POST forms don't
--     load ihp.js's method-override helper. Reached from the /Timeline
--     tile purge button; redirects back to /Timeline with the window.
--
-- Optional query params are read via 'paramOrNothing' — AutoRoute only
-- sees the @cameraId@/@purgeCameraId@ fields.
module Web.Controller.Archive
  ( ArchiveController (..),
  )
where

import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.UUID (UUID)
import Generated.Types
import Hnvr.Core.ArchiveBrowser (parseWhen)
import Hnvr.Core.Authz (CameraAction (..), PageKind (..))
import Hnvr.Core.Playlist (renderEmptyPlaylist, renderVodPlaylist)
import qualified Hnvr.Storage.S3 as S3
import Hnvr.Web.Auth ()
import Hnvr.Web.Authz (ensurePagePerm, ensurePerm, toCameraId)
import Hnvr.Web.PendingPurge (forkCameraPurge)
import Hnvr.Web.View.Archive.Player
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)

data ArchiveController
  = PlayerArchiveAction {cameraId :: !(Id Camera)}
  | PlaylistArchiveAction {cameraId :: !(Id Camera)}
  | -- | Why @purgeCameraId@ and not @cameraId@: IHP AutoRoute generates
    -- the URL @/PurgeRecording?cameraId=…@ from the field name, and the
    -- timeline tiles already carry a @data-cam-id@ convention — keeping
    -- the purge field distinct avoids any future shared-URL collision
    -- (the /Archive filter round-trip that motivated the rename is gone
    -- with the recordings table, but the name is harmless).
    PurgeRecordingAction {purgeCameraId :: !(Id Camera)}
  deriving stock (Eq, Show, Data)

instance AutoRoute ArchiveController

instance Controller ArchiveController where
  beforeAction = ensureIsUser

  action PlayerArchiveAction {cameraId} = do
    ensurePagePerm PageArchive
    ensurePerm ViewArchive (toCameraId cameraId)
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
    ensurePerm ViewArchive (toCameraId cameraId)
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
    -- Roles & ACL (design_docs/13): destructive purge needs the
    -- per-camera purge_archive grant (was: is_admin boolean).
    ensurePerm PurgeArchive (toCameraId purgeCameraId)
    let mFrom = nonemptyParam "purgeFrom" >>= parseWhen
        mTo = nonemptyParam "purgeTo" >>= parseWhen
        -- Back to the timeline at the purged window.
        returnTo = case (mFrom, mTo) of
          (Just f, Just t) -> "/Timeline?from=" <> iso f <> "&to=" <> iso t
          _ -> "/Timeline"
    case (mFrom, mTo) of
      (Just from, Just to) -> do
        _camera <- fetch purgeCameraId
        let cameraUuid = case purgeCameraId of Id u -> u :: UUID
        -- TOMBSTONE, don't delete (migration 0006): stamping
        -- pending_delete_at synchronously hides the recording from
        -- every read path before the redirect re-renders. The hard
        -- DELETE happens in Hnvr.Web.PendingPurge only AFTER the S3
        -- purge is verified empty; if the leader dies mid-purge, the
        -- tombstoned rows survive and the 60s sweeper resumes the
        -- batch. One UPDATE = one round-trip.
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
    where
      iso = T.pack . iso8601Show

-- ---- window resolution ---------------------------------------------

-- | Hard cap for the playlist window (design 05 §Archive playback).
playlistWindowMax :: NominalDiffTime
playlistWindowMax = 6 * 3600

-- | Default playlist window when no from/to is given.
playlistWindowDefault :: NominalDiffTime
playlistWindowDefault = 3600

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

-- ---- query param helpers --------------------------------------------

-- | Optional query param; empty/whitespace treated as absent. Pure —
-- 'paramOrNothing' reads from the request context directly.
nonemptyParam :: (?request :: Request) => ByteString -> Maybe Text
nonemptyParam name =
  case paramOrNothing name of
    Just t | not (T.null (T.strip t)) -> Just (T.strip t)
    _ -> Nothing

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

-- | Resolve S3 config from hnvr.yaml + HNVR_S3_* env overrides.
-- Returns Nothing if neither source is complete. Reads each request —
-- fine for v1; a future slice will cache via FrameworkConfig.
readS3Config :: IO (Maybe S3.S3Config)
readS3Config = S3.readS3Config
