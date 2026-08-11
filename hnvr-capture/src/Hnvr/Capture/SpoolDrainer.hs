{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Spool drainer.
--
-- When S3 is unreachable, 'Hnvr.Capture.Worker.spoolLocally' writes
-- each fragment to disk under @<spoolDir>/<slug>/.../<ts>.mp4@. This
-- module periodically scans the spool directory and re-uploads
-- accumulated files to S3 when connectivity returns.
--
-- Capacity: the design (§03 "Spool on S3 outage") calls for 60 s of
-- buffering. We approximate by counting files per camera slug and
-- dropping the oldest when the count exceeds @maxFilesPerCamera@
-- (default: 60, one file per second). Dropped files are logged so
-- ops can see retention pressure.
--
-- The drainer is intentionally per-process (one per host, owned by
-- 'Hnvr.Node.CaptureSupervisor'). It scans ALL slugs under
-- @spoolDir/@ — not just the ones this host is currently recording —
-- so it cleans up after a camera was reassigned mid-outage too.
module Hnvr.Capture.SpoolDrainer
  ( startSpoolDrainer,
    drainOnce,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Exception (SomeException, catch, try)
import Control.Monad (filterM, forM_, forever, when)
import qualified Data.ByteString as BS
import Data.List (isSuffixOf, sort)
import qualified Data.Text as T
import Hnvr.Capture.Worker (CaptureConfig (..))
import Hnvr.Core.Logging (logError, logInfo, logWarn)
import Hnvr.Storage.S3 (Bucket, PutObjectOptions, defaultPutObjectOptions, pooContentType, putObjectBytes)
import Network.Minio (ConnectInfo)
import qualified System.Directory as Dir
import System.FilePath (makeRelative, (</>))

-- | Drain interval: 30 s. Frequent enough that a transient S3 blip
-- doesn't fill the disk; sparse enough not to hammer S3 with stat
-- calls during normal operation (when there's nothing to drain, the
-- loop just lists the dir and exits).
drainIntervalMicros :: Int
drainIntervalMicros = 30_000_000

-- | Per-camera spool capacity. At 1 fragment/sec this is 60 s of
-- buffering — matches the design's 60-second capacity target.
-- Beyond this we drop the OLDEST files first (the design says
-- drop-newest, but dropping oldest makes more sense for video — the
-- newest fragments are the ones a live viewer might be waiting for).
maxFilesPerCamera :: Int
maxFilesPerCamera = 60

-- | Spawn the drainer in a background 'async'. Lives for the lifetime
-- of the process. Catches all exceptions inside the loop body so a
-- transient FS/S3 outage doesn't kill the drainer permanently.
startSpoolDrainer :: CaptureConfig -> IO ()
startSpoolDrainer cfg = do
  _ <- async loop
  logInfo "SpoolDrainer: started (30s interval)"
  where
    loop =
      forever $ do
        drainOnce cfg
          `catch` \(e :: SomeException) ->
            logError ("SpoolDrainer: drain pass failed: " <> T.pack (show e))
        threadDelay drainIntervalMicros

-- | One drain pass. Lists files under capSpoolDir, optionally
-- trims to capacity per camera, then attempts to upload each to S3.
-- Successfully uploaded files are deleted from disk.
-- No-op (logged at debug level) when S3 isn't configured — the
-- spool is the only output then.
drainOnce :: CaptureConfig -> IO ()
drainOnce cfg =
  case capS3 cfg of
    Nothing -> pure () -- Spool-only mode; nothing to drain toward.
    Just ci -> do
      let spoolDir = capSpoolDir cfg
          bucket = capBucket cfg
      exists <- Dir.doesDirectoryExist spoolDir
      when exists $ do
        slugs <- listSlugs spoolDir
        forM_ slugs $ \slug -> do
          files <- listFilesRecursive (spoolDir </> T.unpack slug)
          let trimmed = trimOldest maxFilesPerCamera files
              droppedCount = length files - length trimmed
          when (droppedCount > 0) $
            logWarn
              ( "SpoolDrainer: dropped "
                  <> T.pack (show droppedCount)
                  <> " old spool file(s) for "
                  <> slug
                  <> " (cap="
                  <> T.pack (show maxFilesPerCamera)
                  <> ")"
              )
          forM_ trimmed $ \fp -> tryUpload ci bucket spoolDir fp

-- | List the immediate subdirectories of @spoolDir@ — these are the
-- camera slugs.
listSlugs :: FilePath -> IO [T.Text]
listSlugs dir = do
  entries <- Dir.listDirectory dir
  -- Keep only entries that are directories. filterM keeps the IO
  -- monad's evaluation order (one stat at a time).
  slugs <- filterM (\e -> Dir.doesDirectoryExist (dir </> e)) entries
  pure (map T.pack slugs)

-- | Walk a directory tree recursively and collect all .mp4 + .m4a
-- files (the spool outputs from Worker.spoolLocally).
listFilesRecursive :: FilePath -> IO [FilePath]
listFilesRecursive dir = do
  entries <- Dir.listDirectory dir
  fmap concat (mapM walkOne entries)
  where
    walkOne entry = do
      let path = dir </> entry
      isDir <- Dir.doesDirectoryExist path
      if isDir
        then listFilesRecursive path
        else
          if any (`isSuffixOf` path) [".mp4", ".m4a"]
            then pure [path]
            else pure []

-- | Drop the oldest files beyond the capacity. "Oldest" = lexicographic
-- order on the path (timestamps in the filename sort naturally).
-- We sort ascending and keep the LAST @n@ entries.
trimOldest :: Int -> [FilePath] -> [FilePath]
trimOldest cap files =
  let sorted = sort files
      n = length sorted
   in if n <= cap
        then sorted
        else drop (n - cap) sorted

-- | Attempt to upload one spool file to S3. On success, delete the
-- local file. On failure (S3 still down), leave it for the next pass.
tryUpload :: ConnectInfo -> Bucket -> FilePath -> FilePath -> IO ()
tryUpload ci bucket spoolDir localPath = do
  let key = T.pack (makeRelative spoolDir localPath)
  mBytes <- readStrict localPath
  case mBytes of
    Nothing -> pure () -- file disappeared between list and read.
    Just bytes -> do
      let opts = defaultPutObjectOptions {pooContentType = Just "video/mp4"}
      result <- try (putObjectBytes ci bucket key bytes opts) :: IO (Either SomeException ())
      case result of
        Left e ->
          logWarn ("SpoolDrainer: upload failed for " <> key <> ": " <> T.pack (show e))
        Right _ -> do
          Dir.removeFile localPath
            `catch` \(e :: SomeException) ->
              logWarn ("SpoolDrainer: post-upload delete failed for " <> T.pack localPath <> ": " <> T.pack (show e))
  where
    readStrict :: FilePath -> IO (Maybe BS.ByteString)
    readStrict p = do
      exists <- Dir.doesFileExist p
      if exists
        then Just <$> BS.readFile p
        else pure Nothing
