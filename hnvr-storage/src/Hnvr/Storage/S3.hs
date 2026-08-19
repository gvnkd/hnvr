{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | SeaweedFS (S3-compatible API) client wrapper.
--
-- Backed by @minio-hs@ instead of the design-doc-suggested @amazonka-s3@.
-- amazonka 2.0 fails to compile under GHC 9.12 without source-level patches
-- (DuplicateRecordFields errors in generated STS modules) that IHP's nix
-- overlay applies but cabal cannot mirror. minio-hs is purpose-built for
-- S3-compatible storage (SeaweedFS, MinIO) and uses path-style addressing
-- by default — exactly what we need.
--
-- Provides the operations the capture pipeline and archive UI need:
--
--   * 'putObjectBytes'   — segment upload (CaptureWorker)
--   * 'getObjectBytes'   — exports / thumbnails (small objects)
--   * 'presignGetUrl'    — 1-hour signed URLs for archive HLS playback
--   * 'listObjectKeys'   — paginated, used by retention sweep
--   * 'deleteObject'     — retention sweep
--
-- Connection info comes from 'S3Config' (env vars at the call site;
-- sops-nix in production). See @design_docs/03-capture-and-storage.md@
-- (\"Fragment → SeaweedFS write protocol\").
module Hnvr.Storage.S3
  ( -- * Configuration
    S3Config (..),
    connectInfo,
    presignConnectInfo,
    readS3ConfigFromEnv,
    readS3Config,

    -- * Operations
    runS3,
    putObjectBytes,
    getObjectBytes,
    presignGetUrl,
    presignGetUrlWithConfig,
    listObjectKeys,
    deleteObject,

    -- * Re-exports (for caller convenience)
    Bucket,
    Object,
    PutObjectOptions,
    defaultPutObjectOptions,
    pooContentType,
    pooUserMetadata,
  )
where

import Control.Applicative ((<|>))
import Control.Exception (throwIO)
import qualified Data.ByteArray as BA (ScrubbedBytes, convert)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Conduit ((.|))
import qualified Data.Conduit as C
import qualified Data.Conduit.Combinators as CC
import Data.Maybe (fromMaybe)
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Hnvr.Core.Config as AppCfg
import Network.Minio
  ( AccessKey (..),
    Bucket,
    ConnectInfo,
    CredentialValue (..),
    GetObjectResponse (..),
    ListItem (..),
    Minio,
    Object,
    ObjectInfo (..),
    PutObjectOptions,
    SecretKey (..),
    UrlExpiry,
    defaultGetObjectOptions,
    defaultPutObjectOptions,
    getObject,
    listObjects,
    pooContentType,
    pooUserMetadata,
    presignedGetObjectUrl,
    putObject,
    removeObject,
    runMinio,
    setCreds,
  )
import System.Environment (lookupEnv)

-- | Static configuration. Pass to 'connectInfo' to build a minio
-- 'ConnectInfo'; pass that to 'runS3' for each operation.
data S3Config = S3Config
  { -- | Internal endpoint used by server-side S3 operations, e.g.
    -- @http://localhost:9000@ or @https://s3.example.internal@.
    s3cEndpoint :: !Text,
    -- | Browser-reachable endpoint used only for presigned GET URLs
    -- (@scheme://host[:port]@, no path prefix). The URL host is part of
    -- the SigV4 signature, so presigning against an internal localhost
    -- endpoint produces links an external browser cannot use. 'Nothing'
    -- falls back to 's3cEndpoint'.
    s3cPublicEndpoint :: !(Maybe Text),
    s3cAccessKey :: !Text,
    s3cSecretKey :: !Text,
    -- | Read-only identity used ONLY for browser-facing presigned GET
    -- URLs. When both are 'Just', 'presignConnectInfo' signs with this
    -- pair instead of the primary credentials, so URLs handed to
    -- end-user browsers carry a read-only identity (SeaweedFS
    -- @Read:\<bucket\>@ + @List:\<bucket\>@ actions) rather than the
    -- admin key. 'Nothing' falls back to the primary pair.
    s3cRoAccessKey :: !(Maybe Text),
    s3cRoSecretKey :: !(Maybe Text),
    -- | Used by helpers; the @putObject*@ functions take an explicit
    -- 'Bucket' so callers can target multiple buckets (segments,
    -- event thumbnails, exports) from one 'S3Config'.
    s3cBucket :: !Text
  }
  deriving stock (Eq, Show)

-- | Build a minio 'ConnectInfo' from static config. Uses the internal
-- endpoint ('s3cEndpoint'); browser-facing presigned URLs should use
-- 'presignConnectInfo' instead.
connectInfo :: S3Config -> ConnectInfo
connectInfo = connectInfoWith s3cEndpoint s3cAccessKey s3cSecretKey

-- | Build the 'ConnectInfo' used for presigned GET URLs. Picks
-- 's3cPublicEndpoint' when set so the signature's host header matches a
-- URL the browser can actually reach; falls back to 's3cEndpoint'.
-- Signs with the read-only identity ('s3cRoAccessKey' /
-- 's3cRoSecretKey') when both are set.
presignConnectInfo :: S3Config -> ConnectInfo
presignConnectInfo =
  connectInfoWith
    (\c -> fromMaybe (s3cEndpoint c) (s3cPublicEndpoint c))
    (\c -> fromMaybe (s3cAccessKey c) (s3cRoAccessKey c))
    (\c -> fromMaybe (s3cSecretKey c) (s3cRoSecretKey c))

connectInfoWith ::
  (S3Config -> Text) ->
  (S3Config -> Text) ->
  (S3Config -> Text) ->
  S3Config ->
  ConnectInfo
connectInfoWith pickEndpoint pickAk pickSk cfg =
  setCreds
    CredentialValue
      { cvAccessKey = AccessKey (pickAk cfg),
        cvSecretKey =
          SecretKey
            (BA.convert (TE.encodeUtf8 (pickSk cfg)) :: BA.ScrubbedBytes),
        cvSessionToken = Nothing
      }
    (fromStringCI (pickEndpoint cfg))
  where
    fromStringCI :: Text -> ConnectInfo
    fromStringCI url = fromString (T.unpack url)

-- | Read the standard @HNVR_S3_*@ environment variables. Required:
-- @HNVR_S3_ENDPOINT@, @HNVR_S3_ACCESS_KEY@, @HNVR_S3_SECRET_KEY@,
-- @HNVR_S3_BUCKET@. Optional: @HNVR_S3_PUBLIC_ENDPOINT@ (browser-facing
-- presign host; ignored when empty), @HNVR_S3_RO_ACCESS_KEY@ +
-- @HNVR_S3_RO_SECRET_KEY@ (read-only presign identity; both or neither).
readS3ConfigFromEnv :: IO (Maybe S3Config)
readS3ConfigFromEnv = do
  mEndpoint <- lookupText "HNVR_S3_ENDPOINT"
  mPublicEndpoint <- (>>= nonEmpty) <$> lookupText "HNVR_S3_PUBLIC_ENDPOINT"
  mAccessKey <- lookupText "HNVR_S3_ACCESS_KEY"
  mSecretKey <- lookupText "HNVR_S3_SECRET_KEY"
  mBucket <- lookupText "HNVR_S3_BUCKET"
  mRoAccessKey <- (>>= nonEmpty) <$> lookupText "HNVR_S3_RO_ACCESS_KEY"
  mRoSecretKey <- (>>= nonEmpty) <$> lookupText "HNVR_S3_RO_SECRET_KEY"
  pure $ do
    endpoint <- mEndpoint
    accessKey <- mAccessKey
    secretKey <- mSecretKey
    bucket <- mBucket
    Just
      S3Config
        { s3cEndpoint = endpoint,
          s3cPublicEndpoint = mPublicEndpoint,
          s3cAccessKey = accessKey,
          s3cSecretKey = secretKey,
          s3cRoAccessKey = mRoAccessKey,
          s3cRoSecretKey = mRoSecretKey,
          s3cBucket = bucket
        }
  where
    lookupText var = fmap T.pack <$> lookupEnv var
    nonEmpty t = if T.null t then Nothing else Just t

-- | Resolve the effective 'S3Config': the YAML config file
-- ('Hnvr.Core.Config.loadAppConfig', path from @$HNVR_CONFIG@ or
-- @.\/hnvr.yaml@) merged with the @HNVR_S3_*@ environment variables.
-- An env var, when set, wins over the file field — the file carries
-- the real credentials, env stays the ad-hoc override for tests and
-- one-off binaries.
readS3Config :: IO (Maybe S3Config)
readS3Config = do
  mFile <- (>>= AppCfg.acS3) <$> AppCfg.loadAppConfig
  mEnv <- readS3ConfigFromEnv
  pure $ case (mFile, mEnv) of
    (Nothing, Nothing) -> Nothing
    (Just f, Nothing) -> Just (fromSection f)
    (Nothing, Just e) -> Just e
    (Just f, Just e) -> Just (mergeEnv (fromSection f) e)
  where
    fromSection s =
      S3Config
        { s3cEndpoint = AppCfg.ssEndpoint s,
          s3cPublicEndpoint = AppCfg.ssPublicEndpoint s,
          s3cAccessKey = AppCfg.ssAccessKey s,
          s3cSecretKey = AppCfg.ssSecretKey s,
          s3cRoAccessKey = AppCfg.ssRoAccessKey s,
          s3cRoSecretKey = AppCfg.ssRoSecretKey s,
          s3cBucket = AppCfg.ssBucket s
        }
    -- 'readS3ConfigFromEnv' is all-or-nothing on the four required
    -- fields, so a present env config carries them all; the file only
    -- fills the optional gaps env leaves unset.
    mergeEnv f e =
      f
        { s3cPublicEndpoint = s3cPublicEndpoint e <|> s3cPublicEndpoint f,
          s3cRoAccessKey = s3cRoAccessKey e <|> s3cRoAccessKey f,
          s3cRoSecretKey = s3cRoSecretKey e <|> s3cRoSecretKey f,
          s3cEndpoint = s3cEndpoint e,
          s3cAccessKey = s3cAccessKey e,
          s3cSecretKey = s3cSecretKey e,
          s3cBucket = s3cBucket e
        }

-- | Run an S3 operation. Wraps 'runMinio' and throws an 'error' on
-- 'Left' so callers see a normal IO exception (which CaptureWorker can
-- catch with `E.catch`).
runS3 :: ConnectInfo -> Minio a -> IO a
runS3 ci action = do
  rs <- runMinio ci action
  case rs of
    Left err -> throwIO (userError ("S3 error: " <> show err))
    Right a -> pure a

-- | Upload a strict 'ByteString' as the body of an S3 object. Returns the
-- ETag (SeaweedFS returns SHA-256 hex for checksummed puts; otherwise the
-- MD5 of the bytes). Caller specifies content-type and any user metadata
-- via the 'PutObjectOptions'.
putObjectBytes ::
  ConnectInfo ->
  Bucket ->
  Object ->
  ByteString ->
  PutObjectOptions ->
  IO ()
putObjectBytes ci bucket key bytes opts = do
  let size = fromIntegral (B.length bytes)
      src = C.yield bytes
  runS3 ci $ putObject bucket key src (Just size) opts

-- | Download an object fully into a strict 'ByteString'. Intended for
-- tests and small objects (thumbnails, exports); segment streaming uses
-- presigned URLs + the HLS player, not this function.
getObjectBytes :: ConnectInfo -> Bucket -> Object -> IO ByteString
getObjectBytes ci bucket key = do
  lbs <- runS3 ci $ do
    resp <- getObject bucket key defaultGetObjectOptions
    C.runConduit (gorObjectStream resp .| CC.sinkLazy)
  pure (BL.toStrict lbs)

-- | Presign a GET URL valid for the given number of seconds (max 7 days
-- for normal credentials). Used by the archive HLS endpoint to hand the
-- browser a direct-to-S3 URL.
presignGetUrl ::
  ConnectInfo ->
  Bucket ->
  Object ->
  UrlExpiry ->
  IO ByteString
presignGetUrl ci bucket key expiry =
  runS3 ci $ presignedGetObjectUrl bucket key expiry [] []

-- | Convenience wrapper: presign using the config's public endpoint
-- ('presignConnectInfo'), not the internal upload/list endpoint.
presignGetUrlWithConfig ::
  S3Config ->
  Bucket ->
  Object ->
  UrlExpiry ->
  IO ByteString
presignGetUrlWithConfig cfg =
  presignGetUrl (presignConnectInfo cfg)

-- | List all object keys under a prefix. Returns them in lexicographic
-- order. Used by the RetentionSweeper to find segments older than the
-- cutoff. Caller should chunk large prefixes by date to keep the listing
-- bounded.
--
-- minio-hs's 'listObjects' conduit re-requests pages while the server
-- reports @IsTruncated@; against our MinIO it loops forever on the same
-- page (next-token never advances), so 'CC.sinkList' would accumulate
-- without bound — the 2026-08-15 leader OOM (RSS 13→47 GB). Guard: S3
-- listings are lexicographically ascending, so the sink stops as soon as
-- a key fails to strictly increase (a repeated page starts over at a
-- smaller key).
listObjectKeys :: ConnectInfo -> Bucket -> Text -> IO [Object]
listObjectKeys ci bucket prefix = do
  keys <-
    runS3 ci $
      C.runConduit $
        listObjects bucket (Just prefix) True .| sinkIncreasing []
  pure (reverse keys)
  where
    sinkIncreasing acc = do
      mx <- C.await
      case mx of
        Nothing -> pure acc
        Just (ListItemPrefix _) -> sinkIncreasing acc
        Just (ListItemObject oi) ->
          let k = oiObject oi
           in case acc of
                (prev : _) | k <= prev -> pure acc
                _ -> sinkIncreasing (k : acc)

-- | Delete an object. Idempotent (no error if the object doesn't exist).
deleteObject :: ConnectInfo -> Bucket -> Object -> IO ()
deleteObject ci bucket key =
  runS3 ci $ removeObject bucket key
