{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Integration binary for the capture pipeline vertical slice.
--
-- Spawns the recording ffmpeg against a single RTSP URL, runs the fMP4
-- parser over its stdout, and writes each emitted fragment to local disk
-- under @<out-dir>/<slug>/<YYYY-MM-DD>/<HH-MM-SS>.mp4@ with a
-- @.sha256@ sidecar.
--
-- Usage:
--
-- @
-- hnvr-record-frames cam-196 udp 'rtsp://admin:123456@192.168.0.196:554/h264PreviewCh01' /tmp/hnvr-out
-- @
--
-- This binary is the smallest end-to-end proof of the Phase 1 capture
-- pipeline. It does NOT touch SeaweedFS, NATS, or Postgres — those land in
-- later slices. It DOES prove that:
--
-- 1. Our ffmpeg flag set produces a parseable fMP4 byte stream.
-- 2. The "Hnvr.Capture.Fmp4" parser slices it into fragments at the right
--    boundaries.
-- 3. Each fragment is independently playable (Sergey can ffprobe each
--    output file).
module Main (main) where

import Crypto.Hash (Digest, SHA256 (..), hash)
import qualified Data.ByteArray as BA (convert)
import qualified Data.ByteString as B
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Hnvr.Capture.Ffmpeg (RecordingConfig (..), Transport (..), recordingArgs)
import Hnvr.Capture.Fmp4 (Fragment (..), feed, finish, initial)
import Hnvr.Core.Time (formatSegmentObjectKeyMs)
import Numeric (showHex)
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitFailure, exitWith)
import System.FilePath (takeDirectory, (<.>), (</>))
import System.IO
  ( BufferMode (..),
    Handle,
    hClose,
    hPutStrLn,
    hSetBuffering,
    stderr,
  )
import System.Process
  ( CreateProcess (..),
    StdStream (..),
    createProcess,
    proc,
    waitForProcess,
  )

main :: IO ()
main = do
  args <- getArgs
  case args of
    [slugS, transportStr, url, outDir] -> do
      transport <- case transportStr of
        "tcp" -> pure TcpTransport
        "udp" -> pure UdpTransport
        _ -> dieErr $ "unknown transport: " ++ transportStr ++ " (use tcp|udp)"
      run slugS transport url outDir
    _ -> dieErr "usage: hnvr-record-frames <slug> <tcp|udp> <rtsp_url> <out_dir>"

run :: String -> Transport -> String -> FilePath -> IO ()
run slugS transport url outDir = do
  let slug = T.pack slugS
      slugDir = outDir </> slugS
  createDirectoryIfMissing True slugDir
  logInfo $
    "starting slug="
      ++ slugS
      ++ " transport="
      ++ show transport
      ++ " url="
      ++ url
      ++ " out="
      ++ slugDir
  let args = recordingArgs RecordingConfig {rcUrl = T.pack url, rcTransport = transport}
  (_, mOut, _, ph) <-
    createProcess
      (proc "ffmpeg" args)
        { std_out = CreatePipe,
          std_err = Inherit
        }
  hOut <- case mOut of
    Just h -> pure h
    Nothing -> dieErr "ffmpeg did not give us a stdout pipe"
  hSetBuffering hOut (BlockBuffering (Just 65536))
  nFrags <- loop slug outDir hOut 0
  hClose hOut
  ec <- waitForProcess ph
  logInfo $ "wrote " ++ show nFrags ++ " fragments; ffmpeg exit=" ++ show ec
  case ec of
    ExitSuccess -> pure ()
    ExitFailure _ -> exitWith ec

loop :: T.Text -> FilePath -> Handle -> Int -> IO Int
loop slug outDir hOut = go initial
  where
    go st !n = do
      chunk <- B.hGetSome hOut 65536
      if B.null chunk
        then do
          case finish st of
            Nothing -> pure n
            Just frag -> writeFragment slug outDir frag >> pure (n + 1)
        else do
          let (frags, st') = feed st chunk
          mapM_ (writeFragment slug outDir) frags
          go st' (n + length frags)

writeFragment :: T.Text -> FilePath -> Fragment -> IO ()
writeFragment slug outDir frag = do
  ts <- getCurrentTime
  case frag of
    InitFragment bs -> do
      let p = outDir </> T.unpack slug </> "init.mp4"
      B.writeFile p bs
      logInfo $ "init -> " ++ p ++ " (" ++ show (B.length bs) ++ " bytes)"
    MediaFragment bs -> do
      let sha = sha256Bytes bs
          key = T.unpack (formatSegmentObjectKeyMs slug ts)
          p = outDir </> key
      createDirectoryIfMissing True (takeDirectory p)
      B.writeFile p bs
      B.writeFile (p <.> "sha256") sha
      logInfo $
        "frag -> "
          ++ p
          ++ " ("
          ++ show (B.length bs)
          ++ " bytes"
          ++ ", sha256="
          ++ showHexSha sha
          ++ ")"

sha256Bytes :: B.ByteString -> B.ByteString
sha256Bytes bs = BA.convert (hash bs :: Digest SHA256)

showHexSha :: B.ByteString -> String
showHexSha = concatMap (pad . flip showHex "") . B.unpack
  where
    pad s@[_] = '0' : s
    pad s = s

logInfo :: String -> IO ()
logInfo = hPutStrLn stderr

dieErr :: String -> IO a
dieErr msg = hPutStrLn stderr msg >> exitFailure
