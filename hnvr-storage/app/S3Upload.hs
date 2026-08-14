{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | S3 integration binary: upload a file to SeaweedFS/MinIO via the
-- 'Hnvr.Storage.S3' wrapper.
--
-- Usage:
--
-- @
-- hnvr-s3-upload <endpoint> <access_key> <secret_key> <bucket> <file> <object_key>
-- @
module Main (main) where

import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import Hnvr.Storage.S3
  ( S3Config (..),
    connectInfo,
    defaultPutObjectOptions,
    pooContentType,
    putObjectBytes,
  )
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  case args of
    [endpoint, ak, sk, bucket, file, key] ->
      run (T.pack endpoint) (T.pack ak) (T.pack sk) (T.pack bucket) file (T.pack key)
    _ -> dieErr "usage: hnvr-s3-upload <endpoint> <access_key> <secret_key> <bucket> <file> <object_key>"

run :: Text -> Text -> Text -> Text -> FilePath -> Text -> IO ()
run endpoint ak sk bucket file key = do
  let cfg =
        S3Config
          { s3cEndpoint = endpoint,
            s3cPublicEndpoint = Nothing,
            s3cAccessKey = ak,
            s3cSecretKey = sk,
            s3cBucket = bucket
          }
      ci = connectInfo cfg
      opts = defaultPutObjectOptions {pooContentType = Just "video/mp4"}
  logInfo $ "uploading " ++ file ++ " -> s3://" ++ T.unpack bucket ++ "/" ++ T.unpack key
  bytes <- B.readFile file
  putObjectBytes ci bucket key bytes opts
  logInfo $ "uploaded " ++ show (B.length bytes) ++ " bytes"

logInfo :: String -> IO ()
logInfo = hPutStrLn stderr

dieErr :: String -> IO a
dieErr msg = hPutStrLn stderr msg >> exitFailure
