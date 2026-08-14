{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Analysis frame source: analysis ffmpeg → RGB24 byte stream →
-- 'Frame' queue.
--
-- Spawns the ffmpeg built by 'Hnvr.Capture.Ffmpeg.analysisArgs', reads
-- stdout, and slices it into @width*height*3@-byte chunks (one RGB24
-- frame each) with a wall-clock timestamp. Frames go onto a bounded
-- 'TBQueue' with drop-oldest semantics — CV must never backpressure
-- ffmpeg's stdout pipe (a blocked pipe stalls the RTSP session and
-- trips the camera into disconnects, pitfall #11 class).
--
-- 'frameSourceLoop' adds the same exponential-backoff supervision as
-- the recording worker (1s → 30s cap): ffmpeg exits on RTSP hiccups,
-- we restart and the queue consumer just sees a gap.
module Hnvr.Capture.FrameSource
  ( FrameSourceConfig (..),
    newFrameQueue,
    writeDropOldest,
    sliceFrames,
    runFrameSource,
    frameSourceLoop,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.STM
import Control.Exception (SomeAsyncException, SomeException, fromException, throwIO, try)
import Control.Monad (forM_, unless, void, when)
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import qualified Data.Vector.Storable as VS
import Hnvr.Capture.Ffmpeg (AnalysisConfig, analysisArgs)
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Core.Logging (logWarn)
import Hnvr.Core.Metrics (Metrics (..))
import System.Exit (ExitCode (..))
import System.IO (Handle)
import System.Process

-- | Static per-camera frame-source config.
data FrameSourceConfig = FrameSourceConfig
  { fscAnalysis :: !AnalysisConfig,
    fscWidth :: !Int,
    fscHeight :: !Int,
    -- | Log-line tag, typically the camera slug.
    fscTag :: !Text,
    -- | Instrumentation hooks ('Hnvr.Core.Metrics.noOpMetrics' when
    -- metrics are disabled).
    fscMetrics :: !Metrics
  }

-- | Bounded frame queue. 4 frames ≈ ~0.8 s of slack at 5 fps —
-- enough for GC pauses, small enough that a wedged analyzer drops
-- frames instead of memory.
newFrameQueue :: IO (TBQueue Frame)
newFrameQueue = newTBQueueIO 4

-- | Drop-oldest write: when the queue is full, evict the head before
-- writing. Returns 'True' when an eviction happened (callers bump a
-- drop counter on it). STM-only so callers compose it into bigger
-- transactions.
writeDropOldest :: TBQueue a -> a -> STM Bool
writeDropOldest q x = do
  full <- isFullTBQueue q
  when full (void (tryReadTBQueue q))
  writeTBQueue q x
  pure full

-- | Slice a byte buffer into complete @frameSize@-byte frames +
-- trailing remainder. Pure; the property tests hang off this.
sliceFrames :: Int -> B.ByteString -> ([B.ByteString], B.ByteString)
sliceFrames frameSize buf
  | frameSize <= 0 = ([], buf)
  | B.length buf < frameSize = ([], buf)
  | otherwise =
      let (complete, rest) = B.splitAt (B.length buf - (B.length buf `mod` frameSize)) buf
       in (go complete, rest)
  where
    go b
      | B.null b = []
      | otherwise = B.take frameSize b : go (B.drop frameSize b)

-- | One ffmpeg lifetime: spawn, slice frames into the queue until
-- EOF/exit. Returns the process exit code (for the backoff loop's
-- logging).
runFrameSource :: FrameSourceConfig -> TBQueue Frame -> IO ExitCode
runFrameSource cfg q = do
  let frameSize = fscWidth cfg * fscHeight cfg * 3
  (_, Just hOut, _, ph) <-
    createProcess
      (proc "ffmpeg" (analysisArgs (fscAnalysis cfg)))
        { std_out = CreatePipe,
          std_err = Inherit
        }
  readLoop hOut frameSize B.empty
  _ <- try (terminateProcess ph) :: IO (Either SomeException ())
  waitForProcess ph
  where
    readLoop :: Handle -> Int -> B.ByteString -> IO ()
    readLoop h frameSize leftover = do
      chunk <- B.hGetSome h (256 * 1024)
      unless (B.null chunk) $ do
        let (frames, rest) = sliceFrames frameSize (leftover <> chunk)
        forM_ frames $ \bytes -> do
          now <- getCurrentTime
          let frame =
                Frame
                  { frameWidth = fscWidth cfg,
                    frameHeight = fscHeight cfg,
                    frameTimestamp = now,
                    frameRgb = VS.generate (B.length bytes) (B.index bytes)
                  }
          dropped <- atomically (writeDropOldest q frame)
          mFrameDecoded (fscMetrics cfg) (fscTag cfg)
          when dropped (mFrameDropped (fscMetrics cfg) (fscTag cfg))
        readLoop h frameSize rest

-- | Supervised frame source: restart ffmpeg on exit with exponential
-- backoff (1s doubling to a 30s cap), logging through the standard
-- 'Hnvr.Core.Logging' channel. Runs forever — cancel the enclosing
-- async to stop. Async exceptions (cancellation) are rethrown, never
-- swallowed: catching 'AsyncCancelled' here would respawn ffmpeg on
-- every stop and make @cancel@ block forever.
frameSourceLoop :: FrameSourceConfig -> TBQueue Frame -> IO ()
frameSourceLoop cfg q = go (0 :: Int)
  where
    go failures = do
      ec <- try (runFrameSource cfg q)
      let delayUs = min 30_000_000 (1_000_000 * (2 ^ min failures 5))
      case ec of
        Right ExitSuccess ->
          logWarn (fscTag cfg <> ": analysis ffmpeg exited cleanly; restarting in " <> tshow delayUs)
        Right (ExitFailure code) ->
          logWarn (fscTag cfg <> ": analysis ffmpeg exit " <> tshow code <> "; backoff " <> tshow delayUs)
        Left (e :: SomeException)
          | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
          | otherwise ->
              logWarn (fscTag cfg <> ": analysis ffmpeg exception " <> T.pack (show e) <> "; backoff " <> tshow delayUs)
      threadDelay delayUs
      go (failures + 1)

    tshow :: Int -> Text
    tshow = T.pack . show
