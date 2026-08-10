{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Archive playback controller.
--
-- Two actions:
--   * 'PlayerAction' — HTML page with @\<video\>@ + hls.js; loads the
--     playlist for the given camera.
--   * 'PlaylistAction' — Generates a VOD @m3u8@ with presigned S3 GET
--     URLs for each segment in the camera's most recent 1-hour window.
--
-- fMP4 HLS requires @EXT-X-VERSION:6@ and a single @EXT-X-MAP@ pointing
-- to the init segment (ftyp+moov). The init.mp4 is uploaded once per
-- camera at the start of recording (see CaptureWorker).
module Hnvr.Web.Controller.Archive
  ( ArchiveController (..),
  )
where

import qualified Data.Text as T
import Generated.Types
import qualified Hnvr.Storage.S3 as S3
import Hnvr.Web.View.Archive.Player
import IHP.ControllerPrelude
import qualified System.Environment as Env

data ArchiveController
  = PlayerAction {cameraId :: !(Id Camera)}
  | PlaylistAction {cameraId :: !(Id Camera)}
  deriving stock (Eq, Show, Data)

instance AutoRoute ArchiveController

instance Controller ArchiveController where
  action PlayerAction {cameraId} = do
    camera <- fetch cameraId
    render PlayerView {..}
  action PlaylistAction {cameraId} = do
    camera <- fetch cameraId
    let cameraUuid = case cameraId of Id u -> u :: UUID
    segments <-
      query @Segment
        |> filterWhere (#cameraId, cameraUuid)
        |> orderByAsc #startTs
        |> limit 3600
        |> fetch
    cfg <- liftIO readS3Config
    m3u8 <- case cfg of
      Nothing -> pure emptyPlaylist
      Just c -> liftIO (buildPlaylist camera segments c)
    setHeader ("Content-Type", "application/vnd.apple.mpegurl")
    setHeader ("Cache-Control", "no-cache")
    renderPlain (cs m3u8 :: LByteString)

-- | Empty VOD playlist (when S3 is not configured or no segments yet).
emptyPlaylist :: Text
emptyPlaylist =
  T.unlines
    [ "#EXTM3U",
      "#EXT-X-VERSION:6",
      "#EXT-X-TARGETDURATION:1",
      "#EXT-X-PLAYLIST-TYPE:VOD",
      "#EXT-X-ENDLIST"
    ]

-- | Build a VOD m3u8 with presigned S3 GET URLs (1-hour expiry) for each
-- segment. The init.mp4 is uploaded once per camera at the start of
-- recording (see CaptureWorker).
buildPlaylist :: Camera -> [Segment] -> S3.S3Config -> IO Text
buildPlaylist camera segments cfg = do
  let ci = S3.connectInfo cfg
      bucket = S3.s3cBucket cfg
      slug = camera.slug
  initUrl <- cs <$> S3.presignGetUrl ci bucket (slug <> "/init.mp4") 3600
  segUrls <- mapM (presignSegment ci bucket) segments
  let entries = concatMap entryFor (zip segUrls segments)
  pure
    $ T.unlines
    $ [ "#EXTM3U",
        "#EXT-X-VERSION:6",
        "#EXT-X-TARGETDURATION:1",
        "#EXT-X-PLAYLIST-TYPE:VOD",
        "#EXT-X-MAP:URI=\"" <> initUrl <> "\""
      ]
    <> entries
    <> ["#EXT-X-ENDLIST"]
  where
    presignSegment ci bucket seg =
      cs <$> S3.presignGetUrl ci bucket seg.objectKey 3600
    entryFor (url, _seg) = ["#EXTINF:1.0,", url]

-- | Read S3 config from environment variables. Returns Nothing if any
-- required var is missing. Reads each request — fine for Slice 6 prototype;
-- future Slice 7 will cache via FrameworkConfig + sops-nix.
readS3Config :: IO (Maybe S3.S3Config)
readS3Config = do
  mEndpoint <- Env.lookupEnv "HNVR_S3_ENDPOINT"
  mAccessKey <- Env.lookupEnv "HNVR_S3_ACCESS_KEY"
  mSecretKey <- Env.lookupEnv "HNVR_S3_SECRET_KEY"
  mBucket <- Env.lookupEnv "HNVR_S3_BUCKET"
  pure $ do
    endpoint <- T.pack <$> mEndpoint
    accessKey <- T.pack <$> mAccessKey
    secretKey <- T.pack <$> mSecretKey
    bucket <- T.pack <$> mBucket
    Just
      S3.S3Config
        { S3.s3cEndpoint = endpoint,
          S3.s3cAccessKey = accessKey,
          S3.s3cSecretKey = secretKey,
          S3.s3cBucket = bucket
        }
