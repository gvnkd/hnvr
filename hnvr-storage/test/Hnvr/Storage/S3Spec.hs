{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Storage.S3".
--
-- Env-gated integration tests against a real S3-compatible backend.
-- Connection params resolve via 'readS3Config' — the dev hnvr.yaml
-- (path from @HNVR_CONFIG@, else @./hnvr.yaml@) with @HNVR_S3_*@ env
-- overrides.
--
-- Tests are skipped unless @HNVR_TEST_INTEGRATION=1@ — keeps
-- @cabal test@ fast in dev (no S3 required).
module Hnvr.Storage.S3Spec (tests) where

import Control.Exception (SomeException, try)
import Control.Monad (forM_, void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.List (sort)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Hnvr.Storage.S3
  ( S3Config (..),
    connectInfo,
    defaultPutObjectOptions,
    deleteObject,
    getObjectBytes,
    listObjectKeys,
    presignConnectInfo,
    presignGetUrl,
    presignGetUrlWithConfig,
    putObjectBytes,
    readS3Config,
  )
import Network.HTTP.Simple (getResponseBody, httpLBS, parseRequest)
import Network.Minio (Bucket, ConnectInfo, Object, isConnectInfoSecure, setRegion)
import System.Environment (lookupEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Storage.S3"
    [ testGroup
        "connectInfo (pure)"
        [ testCase "http endpoint → insecure" $
            isConnectInfoSecure (connectInfo (mkCfg "http://localhost:9100")) @?= False,
          testCase "https endpoint → secure" $
            isConnectInfoSecure (connectInfo (mkCfg "https://s3.example.com")) @?= True,
          testCase "presignConnectInfo falls back to the internal endpoint" $
            isConnectInfoSecure (presignConnectInfo (mkCfg "http://localhost:9100")) @?= False,
          testCase "presignConnectInfo prefers the public endpoint" $
            isConnectInfoSecure
              (presignConnectInfo ((mkCfg "http://localhost:9100") {s3cPublicEndpoint = Just "https://s3.example.com"}))
              @?= True,
          testCase "presign URL carries the primary key when no ro pair" $ do
            url <- presignOffline (mkCfg "http://localhost:9100")
            assertBool "primary key in credential" ("AKPRIMARY" `B.isInfixOf` url),
          testCase "presign URL carries the ro key when set" $ do
            let cfg =
                  (mkCfg "http://localhost:9100")
                    { s3cRoAccessKey = Just "ROKEY",
                      s3cRoSecretKey = Just "ROSECRET"
                    }
            url <- presignOffline cfg
            assertBool "ro key in credential" ("ROKEY" `B.isInfixOf` url)
            assertBool "primary key absent" (not ("AKPRIMARY" `B.isInfixOf` url))
        ],
      testGroup
        "integration (env-gated)"
        [ integrationTest "putObjectBytes + getObjectBytes roundtrip" $
            withS3 $ \ci bucket -> do
              let key = "s3spec-roundtrip-test"
                  payload = "hello hnvr" :: ByteString
              cleanup ci bucket key
              putObjectBytes ci bucket key payload defaultPutObjectOptions
              got <- getObjectBytes ci bucket key
              assertEqual "roundtrip bytes" payload got
              deleteObject ci bucket key,
          integrationTest "putObjectBytes overwrites existing key" $
            withS3 $ \ci bucket -> do
              let key = "s3spec-overwrite-test"
              cleanup ci bucket key
              putObjectBytes ci bucket key "v1" defaultPutObjectOptions
              putObjectBytes ci bucket key "v2-two" defaultPutObjectOptions
              got <- getObjectBytes ci bucket key
              assertEqual "after overwrite" ("v2-two" :: ByteString) got
              deleteObject ci bucket key,
          integrationTest "deleteObject is idempotent" $
            withS3 $ \ci bucket -> do
              let key = "s3spec-delete-idempotent"
              cleanup ci bucket key
              putObjectBytes ci bucket key "x" defaultPutObjectOptions
              deleteObject ci bucket key
              -- Second delete must not throw.
              deleteObject ci bucket key,
          integrationTest "listObjectKeys returns matching keys (any order)" $
            withS3 $ \ci bucket -> do
              let keys =
                    [ "s3spec-list/c/2",
                      "s3spec-list/a/1",
                      "s3spec-list/b/1"
                    ] ::
                      [Object]
              mapM_ (cleanup ci bucket) keys
              mapM_
                (\k -> putObjectBytes ci bucket k "x" defaultPutObjectOptions)
                keys
              got <- listObjectKeys ci bucket "s3spec-list/"
              assertEqual "list (sorted)" (sort keys) (sort got)
              mapM_ (deleteObject ci bucket) keys,
          integrationTest "presignGetUrl returns a non-empty URL" $
            withS3 $ \ci bucket -> do
              let key = "s3spec-presign-test"
                  payload = "signed-content" :: ByteString
              cleanup ci bucket key
              putObjectBytes ci bucket key payload defaultPutObjectOptions
              url <- presignGetUrl ci bucket key 3600
              assertBool "url non-empty" (not (B.null url))
              deleteObject ci bucket key,
          integrationTest "ro-presigned URL actually GETs the object" $
            withS3Cfg $ \cfg bucket -> do
              let key = "s3spec-ro-presign-test"
                  payload = "ro-signed-content" :: ByteString
                  ci = connectInfo cfg
              cleanup ci bucket key
              putObjectBytes ci bucket key payload defaultPutObjectOptions
              url <- presignGetUrlWithConfig cfg bucket key 3600
              -- When the config carries an ro pair the URL MUST be
              -- signed with it — this is the browser fetch path.
              forM_ (s3cRoAccessKey cfg) $ \roAk ->
                assertBool "ro key in credential" (TE.encodeUtf8 roAk `B.isInfixOf` url)
              body <- httpLBS =<< parseRequest (BSC.unpack url)
              assertEqual "fetched bytes" payload (BL.toStrict (getResponseBody body))
              deleteObject ci bucket key
        ]
    ]

mkCfg :: T.Text -> S3Config
mkCfg endpoint =
  S3Config
    { s3cEndpoint = endpoint,
      s3cPublicEndpoint = Nothing,
      s3cAccessKey = "AKPRIMARY",
      s3cSecretKey = "sk",
      s3cRoAccessKey = Nothing,
      s3cRoSecretKey = Nothing,
      s3cBucket = "hnvr-test"
    }

-- ---- helpers -------------------------------------------------------

-- | Presign without touching the network: 'setRegion' disables
-- minio-hs's bucket-location autodiscovery HTTP call, and the SigV4
-- computation itself is local.
presignOffline :: S3Config -> IO ByteString
presignOffline cfg =
  presignGetUrl (setRegion "us-east-1" (presignConnectInfo cfg)) "hnvr-test" "some/key" 3600

-- | Resolve S3 connection params (config file + env overrides), then
-- run the action with a constructed 'ConnectInfo' and resolved bucket.
withS3 :: (ConnectInfo -> Bucket -> IO a) -> IO a
withS3 action = withS3Cfg (action . connectInfo)

-- | Like 'withS3' but hands over the whole 'S3Config' (for presign
-- tests that need the ro identity / public endpoint).
withS3Cfg :: (S3Config -> Bucket -> IO a) -> IO a
withS3Cfg action = do
  mCfg <- readS3Config
  case mCfg of
    Nothing ->
      error "S3Spec: no S3 config (hnvr.yaml missing and HNVR_S3_* unset)"
    Just cfg -> action cfg (s3cBucket cfg)

-- | Best-effort delete before a test, in case a previous run left a key
-- behind. Swallows errors (key not found etc.).
cleanup :: ConnectInfo -> Bucket -> Object -> IO ()
cleanup ci bucket key =
  void (try (deleteObject ci bucket key) :: IO (Either SomeException ()))

-- | Run a test only when HNVR_TEST_INTEGRATION=1; otherwise skip silently.
integrationTest :: String -> IO () -> TestTree
integrationTest name action =
  testCase name $ do
    mEnv <- lookupEnv "HNVR_TEST_INTEGRATION"
    case mEnv of
      Just "1" -> action
      _ -> pure ()
