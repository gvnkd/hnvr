{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Storage.S3".
--
-- Env-gated integration tests against a real S3-compatible backend.
-- The default fixture targets the devenv-managed MinIO at
-- @http://localhost:9100@; override via @HNVR_S3_ENDPOINT@,
-- @HNVR_S3_ACCESS_KEY@, @HNVR_S3_SECRET_KEY@, @HNVR_S3_BUCKET@.
--
-- Tests are skipped unless @HNVR_TEST_INTEGRATION=1@ — keeps
-- @cabal test@ fast in dev (no MinIO required).
module Hnvr.Storage.S3Spec (tests) where

import Control.Exception (SomeException, try)
import Control.Monad (void)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.List (sort)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Hnvr.Storage.S3
  ( S3Config (..),
    connectInfo,
    defaultPutObjectOptions,
    deleteObject,
    getObjectBytes,
    listObjectKeys,
    presignGetUrl,
    putObjectBytes,
  )
import Network.Minio (Bucket, ConnectInfo, Object)
import System.Environment (lookupEnv)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Storage.S3 (integration, env-gated)"
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
          deleteObject ci bucket key
    ]

-- ---- helpers -------------------------------------------------------

-- | Read S3 connection params from env (devenv defaults if unset), then
-- run the action with a constructed 'ConnectInfo' and resolved bucket.
withS3 :: (ConnectInfo -> Bucket -> IO a) -> IO a
withS3 action = do
  mEndpoint <- lookupEnv "HNVR_S3_ENDPOINT"
  mAccess <- lookupEnv "HNVR_S3_ACCESS_KEY"
  mSecret <- lookupEnv "HNVR_S3_SECRET_KEY"
  mBucket <- lookupEnv "HNVR_S3_BUCKET"
  let cfg =
        S3Config
          { s3cEndpoint = T.pack (fromMaybe "http://localhost:9100" mEndpoint),
            s3cAccessKey = T.pack (fromMaybe "minioadmin" mAccess),
            s3cSecretKey = T.pack (fromMaybe "minioadmin" mSecret),
            s3cBucket = T.pack (fromMaybe "hnvr-recordings" mBucket)
          }
  action (connectInfo cfg) (s3cBucket cfg)

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
