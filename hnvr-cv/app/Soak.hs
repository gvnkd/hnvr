{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Soak runner (Phase 3 "longer bake"): live RTSP stream → the exact
-- production analyzer path ('frameSourceLoop' + 'runAnalyzer') for
-- hours, printing throughput / inference-latency / RSS once per
-- report interval.
--
-- Usage:
--   hnvr-cv-soak <rtsp-url> <tcp|udp> <WxH> <fps> <model-path>
--                [--scale WxH] [--minutes N] [--report-every SEC]
--
-- @--scale@ selects the main-stream-relay fallback shape
-- ('ancScale'); omit for native sub-stream decode. EPs come from
-- @HNVR_EXEC_PROVIDERS@ (same as the node), so a bake on hnvr-2
-- exercises TensorRT incl. the engine cache. Without @--minutes@ the
-- bake runs until Ctrl-C; either way a final summary is printed.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Exception (SomeException, try)
import Control.Monad (forever, unless)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Hnvr.Capture.Ffmpeg (AnalysisConfig (..), Transport (..))
import Hnvr.Capture.FrameSource
  ( FrameSourceConfig (..),
    frameSourceLoop,
    newFrameQueue,
  )
import Hnvr.Core.Metrics (Metrics (..), noOpMetrics)
import Hnvr.Cv.Analyzer (defaultAnalyzerConfig, execProvidersFromEnv)
import Hnvr.Cv.AnalyzerRunner (runAnalyzer)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- | CLI options, post-parse.
data Opts = Opts
  { optAnalysis :: !AnalysisConfig,
    optWidth :: !Int,
    optHeight :: !Int,
    optModel :: !Text,
    optMinutes :: !(Maybe Int),
    optReportEvery :: !Int
  }

-- | Mutable bake statistics. Inference timings are bucketed by EP
-- label so a mid-bake TRT→CUDA fallback is visible in the report.
data Stats = Stats
  { stDecoded :: !Int,
    stDropped :: !Int,
    stAnalyzed :: !Int,
    stTracks :: !Int,
    stInf :: !(M.Map Text (Int, Double))
  }

main :: IO ()
main = do
  args <- getArgs
  case parseArgs args of
    Left err -> hPutStrLn stderr err >> usage >> exitFailure
    Right opts -> run opts

usage :: IO ()
usage =
  hPutStrLn stderr $
    "usage: hnvr-cv-soak <rtsp-url> <tcp|udp> <WxH> <fps> <model-path> "
      <> "[--scale WxH] [--minutes N] [--report-every SEC]"

run :: Opts -> IO ()
run opts = do
  statsRef <- newIORef (Stats 0 0 0 0 M.empty)
  q <- newFrameQueue
  eps <- execProvidersFromEnv
  t0 <- getCurrentTime
  let metrics = countingMetrics statsRef
      fsCfg =
        FrameSourceConfig
          { fscAnalysis = optAnalysis opts,
            fscWidth = optWidth opts,
            fscHeight = optHeight opts,
            fscTag = "soak",
            fscMetrics = metrics
          }
  src <- async (frameSourceLoop fsCfg q)
  tick <- async (ticker opts statsRef t0)
  let bake =
        runAnalyzer
          metrics
          defaultAnalyzerConfig
          (optModel opts)
          eps
          q
          (\_frame tracks -> bump statsRef (\st -> st {stAnalyzed = stAnalyzed st + 1, stTracks = length tracks}))
      budgetUs = fmap (\m -> m * 60 * 1_000_000) (optMinutes opts)
  _ <- timeout (fromMaybe maxBound budgetUs) bake
  cancel src
  cancel tick
  report statsRef t0 "FINAL"

countingMetrics :: IORef Stats -> Metrics
countingMetrics ref =
  noOpMetrics
    { mFrameDecoded = \_ -> bump ref (\st -> st {stDecoded = stDecoded st + 1}),
      mFrameDropped = \_ -> bump ref (\st -> st {stDropped = stDropped st + 1}),
      mRecordInference = \ep secs ->
        bump ref (\st -> st {stInf = M.insertWith (\(n', s') (n, s) -> (n + n', s + s')) ep (1, secs) (stInf st)})
    }

bump :: IORef Stats -> (Stats -> Stats) -> IO ()
bump ref f = atomicModifyIORef' ref (\st -> (f st, ()))

ticker :: Opts -> IORef Stats -> UTCTime -> IO ()
ticker opts statsRef t0 =
  forever $ do
    threadDelay (optReportEvery opts * 1_000_000)
    report statsRef t0 "tick"

report :: IORef Stats -> UTCTime -> String -> IO ()
report statsRef t0 tag = do
  st <- readIORef statsRef
  now <- getCurrentTime
  rss <- readRssMb
  let elapsed = round (diffUTCTime now t0) :: Int
      infSummary = T.intercalate ", " [ep <> "=" <> fmtAvg n s | (ep, (n, s)) <- M.toList (stInf st)]
      fmtAvg n s = T.pack (show (fromIntegral (round (s / fromIntegral (max 1 n) * 10_000) :: Int) / 10)) <> "ms"
  hPutStrLn stderr $
    "[soak "
      <> tag
      <> "] elapsed="
      <> show elapsed
      <> "s decoded="
      <> show (stDecoded st)
      <> " dropped="
      <> show (stDropped st)
      <> " analyzed="
      <> show (stAnalyzed st)
      <> " tracks="
      <> show (stTracks st)
      <> " inf["
      <> T.unpack infSummary
      <> "] rss="
      <> maybe "?" (\m -> show m <> "MB") rss

-- | VmRSS from /proc (Linux-only, which is all we deploy on).
readRssMb :: IO (Maybe Int)
readRssMb = do
  r <- try (readFile "/proc/self/status") :: IO (Either SomeException String)
  pure $ case r of
    Left _ -> Nothing
    Right s -> case [words l | l <- lines s, "VmRSS:" `isPrefixOf` l] of
      ((_ : kb : _) : _) -> fmap (`div` 1024) (readMaybe kb)
      _ -> Nothing

-- ---- arg parsing ---------------------------------------------------

parseArgs :: [String] -> Either String Opts
parseArgs args = do
  let (pos, flags) = break (isPrefixOf "--") args
  (url, transport, w, h, fps, model) <- case pos of
    [u, tr, dims, fpsS, m] -> do
      tr' <- parseTransport tr
      (w', h') <- parseDims dims
      fps' <- maybe (Left ("bad fps: " <> fpsS)) Right (readMaybe fpsS)
      pure (u, tr', w', h', fps', m)
    _ -> Left "expected 5 positional args: <rtsp-url> <tcp|udp> <WxH> <fps> <model-path>"
  (scale, rest1) <- takeFlag flags "--scale" (either (const Nothing) Just . parseDims)
  (minutes, rest2) <- takeFlag rest1 "--minutes" readMaybe
  (reportEvery, rest3) <- takeFlag rest2 "--report-every" readMaybe
  unless (null rest3) (Left ("unknown flags: " <> unwords rest3))
  pure
    Opts
      { optAnalysis =
          AnalysisConfig
            { ancUrl = T.pack url,
              ancTransport = transport,
              ancScale = scale,
              ancFps = fps
            },
        optWidth = w,
        optHeight = h,
        optModel = T.pack model,
        optMinutes = minutes,
        optReportEvery = fromMaybe 60 reportEvery
      }

-- | Pop a @--flag value@ pair out of the flag list, applying the value
-- parser. Returns 'Nothing' when the flag is absent.
takeFlag :: [String] -> String -> (String -> Maybe a) -> Either String (Maybe a, [String])
takeFlag flags name parse = case break (== name) flags of
  (before, _ : v : after) -> case parse v of
    Just x -> Right (Just x, before <> after)
    Nothing -> Left ("bad value for " <> name <> ": " <> v)
  (_, [_]) -> Left ("missing value for " <> name)
  _ -> Right (Nothing, flags)

parseTransport :: String -> Either String Transport
parseTransport "tcp" = Right TcpTransport
parseTransport "udp" = Right UdpTransport
parseTransport other = Left ("bad transport: " <> other)

parseDims :: String -> Either String (Int, Int)
parseDims s = case break (== 'x') s of
  (w, 'x' : h) -> case (readMaybe w, readMaybe h) of
    (Just w', Just h') -> Right (w', h')
    _ -> Left ("bad dimensions: " <> s)
  _ -> Left ("bad dimensions (expected WxH): " <> s)
