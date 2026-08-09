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

    -- * Operations
    runS3,
    putObjectBytes,
    getObjectBytes,
    presignGetUrl,
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

import Control.Exception (throwIO)
import Control.Monad.IO.Class (MonadIO, liftIO)
import qualified Data.ByteArray as BA (ScrubbedBytes, convert)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import Data.Conduit ((.|))
import qualified Data.Conduit as C
import qualified Data.Conduit.Combinators as CC
import Data.IORef
import Data.String (fromString)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Network.Minio
  ( AccessKey (..),
    Bucket,
    ConnectInfo,
    CredentialValue (..),
    GetObjectResponse (..),
    ListItem (..),
    Minio,
    MinioErr,
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

-- | Static configuration. Pass to 'connectInfo' to build a minio
-- 'ConnectInfo'; pass that to 'runS3' for each operation.
data S3Config = S3Config
  { -- | Full URL e.g. @http://localhost:9000@ or @https://s3.example.com@.
    s3cEndpoint :: !Text,
    s3cAccessKey :: !Text,
    s3cSecretKey :: !Text,
    -- | Used by helpers; the @putObject*@ functions take an explicit
    -- 'Bucket' so callers can target multiple buckets (segments,
    -- event thumbnails, exports) from one 'S3Config'.
    s3cBucket :: !Text
  }
  deriving stock (Eq, Show)

-- | Build a minio 'ConnectInfo' from static config.
connectInfo :: S3Config -> ConnectInfo
connectInfo cfg =
  setCreds
    CredentialValue
      { cvAccessKey = AccessKey (s3cAccessKey cfg),
        cvSecretKey =
          SecretKey
            (BA.convert (TE.encodeUtf8 (s3cSecretKey cfg)) :: BA.ScrubbedBytes),
        cvSessionToken = Nothing
      }
    (fromStringCI (s3cEndpoint cfg))
  where
    fromStringCI :: Text -> ConnectInfo
    fromStringCI url = fromString (T.unpack url)

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

-- | List all object keys under a prefix. Returns them in lexicographic
-- order. Used by the RetentionSweeper to find segments older than the
-- cutoff. Caller should chunk large prefixes by date to keep the listing
-- bounded.
listObjectKeys :: ConnectInfo -> Bucket -> Text -> IO [Object]
listObjectKeys ci bucket prefix = do
  ref <- newIORef []
  -- sinkList consumes the conduit; we then map to extract Object keys.
  items <-
    runS3 ci $
      C.runConduit $
        listObjects bucket (Just prefix) True .| CC.sinkList
  pure [oiObject oi | ListItemObject oi <- items]

-- | Delete an object. Idempotent (no error if the object doesn't exist).
deleteObject :: ConnectInfo -> Bucket -> Object -> IO ()
deleteObject ci bucket key =
  runS3 ci $ removeObject bucket key
