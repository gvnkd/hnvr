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
--   * 'PurgeRecordingAction' — admin-only; deletes the window's S3
--     objects (best-effort) and segment rows, mirroring RetentionSweeper
--     semantics. Named "Purge", not "Delete": AutoRoute maps @Delete*@
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

import qualified Control.Exception as E
import Data.List (sortOn)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Ord (Down (..))
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, UTCTime (..), addUTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.Time.Format.ISO8601 (iso8601ParseM)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Generated.Types
import Hnvr.Core.Playlist (renderEmptyPlaylist, renderVodPlaylist)
import Hnvr.Core.Recording (Recording (..), Span (..), groupRecordings, recGaps)
import qualified Hnvr.Storage.S3 as S3
import Hnvr.Web.Auth ()
import Hnvr.Web.View.Archive.Index
import Hnvr.Web.View.Archive.Player
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (currentUserOrNothing, ensureIsUser)
import qualified System.Environment as Env
import Text.Read (readMaybe)

data ArchiveController
  = ArchiveAction
  | PlayerArchiveAction {cameraId :: !(Id Camera)}
  | PlaylistArchiveAction {cameraId :: !(Id Camera)}
  | PurgeRecordingAction {cameraId :: !(Id Camera)}
  deriving stock (Eq, Show, Data)

instance AutoRoute ArchiveController

-- | Gap between consecutive segments that splits one recording into two.
splitTolerance :: NominalDiffTime
splitTolerance = 30

-- | Hole threshold surfaced inside a recording (badge "N gaps").
gapMin :: NominalDiffTime
gapMin = 1.5

-- | Hard cap for the browser window (fetch size guard).
browseWindowMax :: NominalDiffTime
browseWindowMax = 24 * 3600

-- | Hard cap for the playlist window (design 05 §Archive playback).
playlistWindowMax :: NominalDiffTime
playlistWindowMax = 6 * 3600

-- | Default playlist window when no from/to is given.
playlistWindowDefault :: NominalDiffTime
playlistWindowDefault = 3600

pageSize :: Int
pageSize = 25

instance Controller ArchiveController where
  beforeAction = ensureIsUser

  action ArchiveAction = do
    let fltCamera = nonemptyParam "cameraId"
        fltFrom = nonemptyParam "from"
        fltTo = nonemptyParam "to"
        fltQ = nonemptyParam "q"
        fltMinDur = nonemptyParam "minDuration" >>= readMaybe . T.unpack
        page = max 1 (fromMaybe 1 (nonemptyParam "page" >>= readMaybe . T.unpack))

    cameras <- query @Camera |> orderByAsc #slug |> fetch
    let slugMap = M.fromList [(camUuid c, c.slug) | c <- cameras]

    now <- liftIO getCurrentTime
    let (mFrom, mTo, notice) = resolveBrowseWindow now (fltFrom >>= parseWhen) (fltTo >>= parseWhen)
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
        let q0 = query @Segment |> orderByAsc #startTs
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
        total = length recs
        totalPages = max 1 ((total + pageSize - 1) `div` pageSize)
        pageRecs = take pageSize (drop ((page - 1) * pageSize) recs)
        rows = map (toRow slugMap) pageRecs
        isAdmin = maybe False (.isAdmin) (currentUserOrNothing @User)
        queryString = browseQueryString fltCamera fltFrom fltTo fltQ fltMinDur
    render IndexView {..}
    where
      toSpan s =
        Span
          { spCameraId = s.cameraId,
            spStart = s.startTs,
            spEnd = s.endTs,
            spBytes = fromIntegral s.bytes,
            spHasAudio = s.hasAudio,
            spObjectKey = s.objectKey
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
                rrGapCount = length (recGaps gapMin r)
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
  action PurgeRecordingAction {cameraId} = do
    let isAdmin = maybe False (.isAdmin) (currentUserOrNothing @User)
    if not isAdmin
      then setErrorMessage "Recording deletion requires an admin user"
      else do
        let mFrom = nonemptyParam "from"
            mTo = nonemptyParam "to"
        case (mFrom >>= parseWhen, mTo >>= parseWhen) of
          (Just from, Just to) -> do
            camera <- fetch cameraId
            let cameraUuid = case cameraId of Id u -> u :: UUID
            segments <-
              query @Segment
                |> filterWhere (#cameraId, cameraUuid)
                |> filterWhereGreaterThan (#endTs, from)
                |> filterWhereLessThanOrEqualTo (#startTs, to)
                |> fetch
            mCfg <- liftIO readS3Config
            nObjects <- case mCfg of
              Nothing -> pure 0
              Just cfg ->
                liftIO (purgeObjects cfg camera.slug from to (map (.objectKey) segments))
            deleteRecords segments
            setSuccessMessage
              ( tshow (length segments)
                  <> " segment row(s) deleted; "
                  <> tshow nObjects
                  <> " S3 delete(s) issued"
              )
          _ -> setErrorMessage "Purge requires valid from/to timestamps"
    redirectTo ArchiveAction

-- ---- window resolution ---------------------------------------------

-- | Browser window: defaults to the last 24 h; clamps to 'browseWindowMax'
-- with a user-facing notice when a wider range is requested.
resolveBrowseWindow :: UTCTime -> Maybe UTCTime -> Maybe UTCTime -> (Maybe UTCTime, Maybe UTCTime, Maybe Text)
resolveBrowseWindow now mFrom mTo =
  case (mFrom, mTo) of
    (Just f, Just t)
      | t > f && diffUTCTime t f > browseWindowMax ->
          (Just f, Just (addUTCTime browseWindowMax f), Just "Window clamped to 24h")
      | t > f -> (Just f, Just t, Nothing)
      | otherwise -> (Just (addUTCTime (-browseWindowMax) now), Just now, Just "Invalid from/to; showing last 24h")
    (Just f, Nothing) -> (Just f, Just (addUTCTime browseWindowMax f), Nothing)
    (Nothing, Just t) -> (Just (addUTCTime (-browseWindowMax) t), Just t, Nothing)
    (Nothing, Nothing) -> (Just (addUTCTime (-browseWindowMax) now), Just now, Nothing)

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

-- | Accepts full ISO 8601 and the @datetime-local@ form
-- (@2026-08-11T14:30[@:SS]@, assumed UTC).
parseWhen :: Text -> Maybe UTCTime
parseWhen t =
  iso8601ParseM s
    <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M" s
    <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S" s
  where
    s = T.unpack t

browseQueryString :: Maybe Text -> Maybe Text -> Maybe Text -> Maybe Text -> Maybe Int -> Text
browseQueryString mCam mFrom mTo mQ mMinDur =
  T.concat
    [ p "cameraId" mCam,
      p "from" mFrom,
      p "to" mTo,
      p "q" mQ,
      p "minDuration" (tshow <$> mMinDur)
    ]
  where
    p _ Nothing = ""
    p name (Just v) = "&" <> name <> "=" <> v

-- | Delete every S3 object covering the window: row keys PLUS orphans
-- found by prefix listing. Orphans exist because legacy rows stored
-- second-precision keys while uploads used millisecond precision
-- (pre-fix worker, pitfall #25 class) — row-key deletes were silent
-- no-ops for those segments. The prefix pass lists
-- @\<slug\>/\<YYYY-MM-DD\>/@ per day in the window and deletes objects
-- whose key-embedded timestamp falls inside @[from, to]@, independent
-- of what the (possibly already-deleted) DB rows said.
purgeObjects :: S3.S3Config -> Text -> UTCTime -> UTCTime -> [Text] -> IO Int
purgeObjects cfg slug from to rowKeys = do
  let ci = S3.connectInfo cfg
      bucket = S3.s3cBucket cfg
      days = enumFromTo (utctDay from) (utctDay to)
  listed <- fmap concat $ forM days $ \d ->
    S3.listObjectKeys ci bucket (slug <> "/" <> tshow d <> "/")
      `E.catch` \(_ :: E.SomeException) -> pure []
  let orphanKeys =
        [ k
        | k <- listed,
          Just ts <- [parseKeyTimestamp slug k],
          ts >= from && ts <= to
        ]
      keys = nub (rowKeys <> orphanKeys)
  forM_ keys $ \k ->
    S3.deleteObject ci bucket k
      `E.catch` \(_ :: E.SomeException) -> pure ()
  pure (length keys)

-- | Extract the capture timestamp from an object key
-- (@slug/2026-08-11/15-02-55[.442].mp4@). Returns Nothing for keys
-- that don't match the segment layout (e.g. @init.mp4@ — never
-- purged; future playlists still need it).
parseKeyTimestamp :: Text -> Text -> Maybe UTCTime
parseKeyTimestamp slug key = do
  rest <- T.stripPrefix (slug <> "/") key
  body <- T.stripSuffix ".mp4" rest
  let s = T.unpack body
  parseTimeM True defaultTimeLocale "%Y-%m-%d/%H-%M-%S%Q" s
    <|> parseTimeM True defaultTimeLocale "%Y-%m-%d/%H-%M-%S" s

-- ---- playlist rendering ---------------------------------------------

-- | Build a VOD m3u8 with presigned S3 GET URLs (1-hour expiry) for each
-- segment; pure rendering lives in 'Hnvr.Core.Playlist'.
buildPlaylist :: Camera -> [Segment] -> S3.S3Config -> IO Text
buildPlaylist camera segments cfg = do
  let ci = S3.connectInfo cfg
      bucket = S3.s3cBucket cfg
      slug = camera.slug
  initUrl <- cs <$> S3.presignGetUrl ci bucket (slug <> "/init.mp4") 3600
  segUrls <- mapM (presignSegment ci bucket) segments
  let entries = zipWith entry segments segUrls
  pure (renderVodPlaylist initUrl entries)
  where
    presignSegment ci bucket seg =
      cs <$> S3.presignGetUrl ci bucket seg.objectKey 3600
    entry seg url = (realToFrac (diffUTCTime seg.endTs seg.startTs), url)

-- | Read S3 config from environment variables. Returns Nothing if any
-- required var is missing. Reads each request — fine for v1; a future
-- slice will cache via FrameworkConfig + sops-nix.
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
