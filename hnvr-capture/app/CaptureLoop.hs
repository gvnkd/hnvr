{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Integration binary for the supervised capture pipeline.
--
-- Spawns one CaptureWorker for a single camera, wires it to NATS + S3 +
-- local spool, and runs until SIGINT. Verifies the full vertical slice:
--
--   * ffmpeg subprocess supervision with exponential backoff
--   * fMP4 parser slicing fragments at moof/mdat boundaries
--   * S3 put on each fragment (with local spool fallback on S3 failure)
--   * NATS publish of 'SegmentWritten' on @hnvr.events@
--
-- Usage:
--
-- @
-- hnvr-capture-loop <slug> <tcp|udp> <rtsp_url>
--   [--nats nats://user:pass\@host:4222]
--   [--s3 http://host:9000 <access_key> <secret_key> <bucket>]
--   [--spool-dir /tmp/hnvr-spool]
--   [--host host-id]
-- @
module Main (main) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (nil)
import Hnvr.Capture.Worker
  ( CameraConfig (..),
    CaptureConfig (..),
    Transport (..),
    captureWorker,
  )
import Hnvr.Core.Id (CameraId (..), HostId (..))
import Hnvr.Nats.Bus (BusConfig (..), defaultConfig, withBus)
import Hnvr.Storage.S3 (S3Config (..), connectInfo)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  args <- getArgs
  case args of
    slugS : transportStr : url : rest ->
      case parseFlags rest defaultOpts of
        Left err -> dieErr err
        Right opts -> do
          transport <- case transportStr of
            "tcp" -> pure TcpTransport
            "udp" -> pure UdpTransport
            _ -> dieErr $ "unknown transport: " ++ transportStr ++ " (use tcp|udp)"
          run slugS transport url opts
    _ -> dieErr usage

data Opts = Opts
  { optNatsUri :: Maybe String,
    optS3 :: Maybe S3Config,
    optSpoolDir :: FilePath,
    optHostId :: Text
  }

defaultOpts :: Opts
defaultOpts =
  Opts
    { optNatsUri = Nothing,
      optS3 = Nothing,
      optSpoolDir = "/tmp/hnvr-spool",
      optHostId = "hnvr-dev"
    }

parseFlags :: [String] -> Opts -> Either String Opts
parseFlags [] o = Right o
parseFlags ("--nats" : uri : rest) o =
  parseFlags rest (o {optNatsUri = Just uri})
parseFlags ("--s3" : ep : ak : sk : bucket : rest) o =
  parseFlags
    rest
    ( o
        { optS3 =
            Just
              S3Config
                { s3cEndpoint = T.pack ep,
                  s3cAccessKey = T.pack ak,
                  s3cSecretKey = T.pack sk,
                  s3cBucket = T.pack bucket
                }
        }
    )
parseFlags ("--spool-dir" : d : rest) o =
  parseFlags rest (o {optSpoolDir = d})
parseFlags ("--host" : h : rest) o =
  parseFlags rest (o {optHostId = T.pack h})
parseFlags (flag : _) _ = Left $ "unknown flag: " ++ flag

usage :: String
usage =
  "usage: hnvr-capture-loop <slug> <tcp|udp> <rtsp_url>\
  \ [--nats URI] [--s3 EP AK SK BUCKET] [--spool-dir DIR] [--host HOSTID]"

run :: String -> Transport -> String -> Opts -> IO ()
run slugS transport url opts = do
  let slug = T.pack slugS
      cam =
        CameraConfig
          { ccId = CameraId nil,
            ccSlug = slug,
            ccRtspUrl = T.pack url,
            ccTransport = transport
          }
      cfgBase =
        CaptureConfig
          { capBus = Nothing,
            capS3 = fmap connectInfo (optS3 opts),
            capBucket = maybe "hnvr-recordings" s3cBucket (optS3 opts),
            capHostId = HostId (optHostId opts),
            capSpoolDir = optSpoolDir opts
          }
  case optNatsUri opts of
    Nothing -> do
      hPutStrLn stderr "[main] no NATS configured; running silent"
      captureWorker cfgBase cam
    Just uri ->
      withBus defaultConfig {busUri = uri} $ \bus ->
        captureWorker cfgBase {capBus = Just bus} cam

dieErr :: String -> IO a
dieErr msg = hPutStrLn stderr msg >> exitFailure
