{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Capture.SpoolDrainer".
--
-- 'trimOldest' is the pure capacity policy; 'drainOnce' is exercised
-- against a temp spool dir in two degraded modes: no S3 configured
-- (no-op) and S3 unreachable (files must remain for the next pass —
-- the drainer never loses a segment it couldn't upload).
module Hnvr.Capture.SpoolDrainerSpec (tests) where

import Control.Exception (bracket)
import Control.Monad (forM_)
import Data.Time.Clock (diffTimeToPicoseconds, getCurrentTime, utctDayTime)
import Hnvr.Capture.SpoolDrainer (drainOnce, trimOldest)
import Hnvr.Capture.Worker (CaptureConfig (..))
import Hnvr.Core.Id (HostId (..))
import Hnvr.Core.Metrics (noOpMetrics)
import Hnvr.Storage.S3 (S3Config (..), connectInfo)
import Network.Minio (ConnectInfo)
import qualified System.Directory as Dir
import System.FilePath ((</>))
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Capture.SpoolDrainer"
    [ testGroup
        "trimOldest"
        [ testCase "under cap → all files, sorted ascending" $
            trimOldest 3 ["b.mp4", "a.mp4", "c.mp4"] @?= ["a.mp4", "b.mp4", "c.mp4"],
          testCase "exactly at cap → unchanged" $
            trimOldest 2 ["02.mp4", "01.mp4"] @?= ["01.mp4", "02.mp4"],
          testCase "over cap → keeps the newest cap files, drops oldest" $
            trimOldest 2 ["01.mp4", "02.mp4", "03.mp4", "04.mp4"] @?= ["03.mp4", "04.mp4"],
          testCase "cap 0 → drops everything" $
            trimOldest 0 ["a.mp4"] @?= []
        ],
      testCase "drainOnce with no S3 configured is a no-op" $
        withSpool $ \spoolDir -> do
          seedSpool spoolDir 3
          drainOnce (cfg spoolDir Nothing)
          left <- spoolFiles spoolDir
          assertEqual "files untouched" 3 (length left),
      testCase "drainOnce with unreachable S3 leaves files for the next pass" $
        withSpool $ \spoolDir -> do
          seedSpool spoolDir 3
          let dead =
                connectInfo
                  S3Config
                    { s3cEndpoint = "http://127.0.0.1:1",
                      s3cPublicEndpoint = Nothing,
                      s3cAccessKey = "k",
                      s3cSecretKey = "s",
                      s3cRoAccessKey = Nothing,
                      s3cRoSecretKey = Nothing,
                      s3cBucket = "hnvr-test"
                    }
          -- minio-hs retries connection failures with growing backoff,
          -- so a full drainOnce against a dead endpoint never returns;
          -- bound the pass and assert the property we actually care
          -- about: a failed upload never loses the local file.
          _ <- timeout 5_000_000 (drainOnce (cfg spoolDir (Just dead)))
          left <- spoolFiles spoolDir
          assertEqual "nothing lost on S3 outage" 3 (length left)
    ]

-- ---- fixtures ------------------------------------------------------

cfg :: FilePath -> Maybe ConnectInfo -> CaptureConfig
cfg spoolDir mCi =
  CaptureConfig
    { capBus = Nothing,
      capS3 = mCi,
      capBucket = "hnvr-test",
      capHostId = HostId "test-host",
      capSpoolDir = spoolDir,
      capMetrics = noOpMetrics
    }

withSpool :: (FilePath -> IO ()) -> IO ()
withSpool k = do
  tmp <- Dir.getTemporaryDirectory
  now <- getCurrentTime
  let dir = tmp </> ("hnvr-spool-test-" <> show (diffTimeToPicoseconds (utctDayTime now)))
  bracket (Dir.createDirectoryIfMissing True dir >> pure dir) Dir.removePathForcibly k

seedSpool :: FilePath -> Int -> IO ()
seedSpool spoolDir n = do
  let dayDir = spoolDir </> "cam-test" </> "2026-08-14"
  Dir.createDirectoryIfMissing True dayDir
  forM_ [1 .. n] $ \i ->
    writeFile (dayDir </> ("12-00-0" <> show i <> ".000.mp4")) ("frag" <> show i)

spoolFiles :: FilePath -> IO [FilePath]
spoolFiles spoolDir = do
  slugs <- Dir.listDirectory spoolDir
  fmap concat . mapM (walk . (spoolDir </>)) $ slugs
  where
    walk dir = do
      entries <- Dir.listDirectory dir
      fmap concat . mapM (\e -> go (dir </> e)) $ entries
    go p = do
      isDir <- Dir.doesDirectoryExist p
      if isDir then walk p else pure [p]
