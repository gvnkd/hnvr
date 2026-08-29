{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /EventClips — playback + purge for the separated event video
-- store. Clips are self-contained fMP4 mini-archives under one S3
-- prefix ('Hnvr.Core.Clip'), so the playlist action lists the prefix
-- and presigns every object — no segments-table involvement.
module Web.Controller.EventClips
  ( EventClipsController (..),
  )
where

import qualified Control.Concurrent.Async as Async
import Control.Exception (SomeException, try)
import Control.Monad (void)
import Data.List (sort)
import Generated.Types
import Hnvr.Core.Authz (CameraAction (..))
import Hnvr.Core.Clip (clipInitKey, playlistDurations)
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Core.Playlist (renderEmptyPlaylist, renderVodPlaylist)
import qualified Hnvr.Storage.S3 as S3
import Hnvr.Web.Auth ()
import Hnvr.Web.Authz (ensurePerm)
import Hnvr.Web.RetentionSweeper (purgeClipObjects)
import Hnvr.Web.View.EventClips.Player
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)
import IHP.ModelSupport (Id' (Id))

data EventClipsController
  = PlayerEventClipAction {clipId :: Id EventClip}
  | PlaylistEventClipAction {playlistClipId :: Id EventClip}
  | -- | POST (no Delete* prefix — IHP maps those to HTTP DELETE,
    -- pitfall #82). Admin-gated; tombstones the row synchronously so
    -- it vanishes from /Events immediately, then purges S3 async.
    PurgeEventClipAction {purgeClipId :: Id EventClip}
  deriving stock (Eq, Show, Data)

instance AutoRoute EventClipsController

instance Controller EventClipsController where
  beforeAction = ensureIsUser

  action PlayerEventClipAction {clipId} = do
    clip <- fetch clipId
    ensurePerm ViewArchive (CameraId clip.cameraId)
    -- FK fields are bare UUIDs in this IHP version (same as
    -- Rule.cameraId) — wrap before fetching.
    camera <- fetchOneOrNothing (Id clip.cameraId :: Id Camera)
    case camera of
      Nothing -> redirectToPath "/Events"
      Just cam -> render ClipPlayerView {clip = clip, camera = cam}
  action PlaylistEventClipAction {playlistClipId} = do
    clip <- fetch playlistClipId
    ensurePerm ViewArchive (CameraId clip.cameraId)
    m3u8 <- case clip.pendingDeleteAt of
      Just _ -> pure renderEmptyPlaylist
      Nothing -> do
        cfg <- liftIO S3.readS3Config
        case cfg of
          Nothing -> pure renderEmptyPlaylist
          Just c -> liftIO (buildClipPlaylist clip c)
    setHeader ("Content-Type", "application/vnd.apple.mpegurl")
    setHeader ("Cache-Control", "private, max-age=0")
    renderPlain (cs m3u8 :: LByteString)
  action PurgeEventClipAction {purgeClipId} = do
    clip <- fetch purgeClipId
    -- Roles & ACL (design_docs/13): clips are recordings — destructive
    -- purge needs the per-camera purge_archive grant (was: is_admin).
    ensurePerm PurgeArchive (CameraId clip.cameraId)
    -- Tombstone first: the row disappears from every read path
    -- before the redirect re-renders. Hard DELETE after the S3
    -- purge verifies empty; the RetentionSweeper resumes stale
    -- tombstones (90 s grace) if this worker dies mid-purge.
    _ <-
      sqlExec
        "UPDATE event_clips SET pending_delete_at = NOW() \
        \ WHERE id = ? AND pending_delete_at IS NULL"
        (Only (case purgeClipId of Id u -> u))
    let mc = ?modelContext
        prefix = clip.objectPrefix
    _ <-
      liftIO $ Async.async $ do
        r <- try $ do
          mS3 <- S3.readS3Config
          forM_ mS3 $ \cfg -> do
            failures <- purgeClipObjects cfg prefix
            when (failures == 0)
              $ let ?modelContext = mc
                 in void
                      $ sqlExec
                        "DELETE FROM event_clips WHERE id = ? AND pending_delete_at IS NOT NULL"
                        (Only (case purgeClipId of Id u -> u))
        case r of
          Right _ -> pure ()
          Left (_ :: SomeException) ->
            -- Row stays tombstoned; sweeper converges.
            pure ()
    setSuccessMessage "Clip deleted"
    redirectToPath "/Events"

-- | Presign init.mp4 + every fragment under the clip's prefix and
-- render the VOD m3u8. Fragment durations come from the key-embedded
-- timestamps ('playlistDurations'); LIST order is lexical = play
-- order.
buildClipPlaylist :: EventClip -> S3.S3Config -> IO Text
buildClipPlaylist clip cfg = do
  let bucket = S3.s3cBucket cfg
      prefix = clip.objectPrefix
  objs <- S3.listObjectKeys (S3.connectInfo cfg) bucket prefix
  let fragKeys = sort (filter (/= clipInitKey prefix) objs)
      durs = playlistDurations fragKeys
  initUrl <- cs <$> S3.presignGetUrlWithConfig cfg bucket (clipInitKey prefix) 3600
  entries <- forM durs $ \(key, dur) -> do
    url <- cs <$> S3.presignGetUrlWithConfig cfg bucket key 3600
    pure (dur, url)
  pure (renderVodPlaylist initUrl entries)
