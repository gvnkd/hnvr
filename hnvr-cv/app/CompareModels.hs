{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | A/B model comparison (Phase 3 accuracy decision): pull N frames
-- from one camera stream, run each through two ONNX models, and print
-- a per-frame + summary comparison so the per-camera
-- YOLOv8n-320 vs YOLOv8s-640 call is made on data, not vibes.
--
-- Usage:
--   hnvr-cv-compare <rtsp-url> <tcp|udp> <WxH> <fps> <modelA> <modelB>
--                   [--frames N] [--png-dir DIR] [--conf F] [--scale WxH]
--
-- Raw detections are decoded at @--conf@ (default 0.10 — below the
-- production 0.35 so marginal detections are visible); confirmed
-- tracks come from threading each frame through SORT, exactly as
-- 'Hnvr.Cv.Analyzer.analyzeFrame' does. @--png-dir@ writes one
-- track-annotated PNG per frame per model for eyeballing. @--scale@
-- selects the relay main-stream-with-scale shape (frame dims then
-- equal the scale).
--
-- EPs come from @HNVR_EXEC_PROVIDERS@ (production-realistic; TRT fp16
-- vs CPU fp32 rounding is part of what we're deciding on).
module Main (main) where

import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.STM (atomically, readTBQueue)
import Control.Exception (evaluate)
import Control.Monad (forM_, unless)
import qualified Data.ByteString.Lazy as BL
import Data.List (isPrefixOf)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Vector as V
import Hnvr.Capture.Ffmpeg (AnalysisConfig (..), Transport (..))
import Hnvr.Capture.FrameSource
  ( FrameSourceConfig (..),
    frameSourceLoop,
    newFrameQueue,
  )
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Core.Metrics (noOpMetrics)
import Hnvr.Cv.Analyzer (Analyzer (..), AnalyzerConfig (..), defaultAnalyzerConfig, execProvidersFromEnv, withAnalyzer)
import Hnvr.Cv.DebugRender (renderDebugPng)
import Hnvr.Cv.Decode (Detection (..), cocoClassName, decode, nms, unletterboxDetection)
import Hnvr.Cv.OnnxRuntime (infer)
import Hnvr.Cv.Preprocess (letterboxGeometry, preprocessTo, toTensor)
import Hnvr.Cv.Tracker.Sort (Track)
import qualified Hnvr.Cv.Tracker.Sort as Sort
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (hPutStrLn, stderr)
import System.Timeout (timeout)
import Text.Read (readMaybe)

-- | CLI options, post-parse.
data Opts = Opts
  { optAnalysis :: !AnalysisConfig,
    optWidth :: !Int,
    optHeight :: !Int,
    optModelA :: !FilePath,
    optModelB :: !FilePath,
    optFrames :: !Int,
    optPngDir :: !(Maybe FilePath),
    optConf :: !Float
  }

-- | Per-frame comparison row.
data FrameRow = FrameRow
  { frIdx :: !Int,
    frFrame :: !Frame,
    frDetsA, frDetsB :: ![DetTxt],
    frTracksA, frTracksB :: ![Track]
  }

-- | Printable detection: (class name, score).
type DetTxt = (T.Text, Float)

main :: IO ()
main = do
  args <- getArgs
  case parseArgs args of
    Left err -> hPutStrLn stderr err >> usage >> exitFailure
    Right opts -> run opts

usage :: IO ()
usage =
  hPutStrLn stderr $
    "usage: hnvr-cv-compare <rtsp-url> <tcp|udp> <WxH> <fps> <modelA> <modelB> "
      <> "[--frames N] [--png-dir DIR] [--conf F]"

run :: Opts -> IO ()
run opts = do
  frames <- grabFrames opts
  eps <- execProvidersFromEnv
  let cfg = defaultAnalyzerConfig {acConfThreshold = optConf opts}
  hPutStrLn stderr "=== model A pass ==="
  resA <- withAnalyzer cfg (T.pack (optModelA opts)) eps $ \an0 -> mapM (inferFrame an0) (zip [1 ..] frames)
  hPutStrLn stderr "=== model B pass ==="
  resB <- withAnalyzer cfg (T.pack (optModelB opts)) eps $ \an0 -> mapM (inferFrame an0) (zip [1 ..] frames)
  let rows = zipWith3 mkRow frames resA resB
  mapM_ (printRow opts) rows
  maybe (pure ()) (dumpPngs rows) (optPngDir opts)
  printSummary opts rows
  where
    mkRow frame (i, detsA, tracksA) (_, detsB, tracksB) =
      FrameRow i frame detsA detsB tracksA tracksB

-- | Collect N frames from the live stream. Bounded by a generous
-- deadline so a dead camera fails the run instead of hanging it.
grabFrames :: Opts -> IO [Frame]
grabFrames opts = do
  q <- newFrameQueue
  let fsCfg =
        FrameSourceConfig
          { fscAnalysis = optAnalysis opts,
            fscWidth = optWidth opts,
            fscHeight = optHeight opts,
            fscTag = "compare",
            fscMetrics = noOpMetrics
          }
  src <- async (frameSourceLoop fsCfg q)
  let budgetUs = 120_000_000 + optFrames opts * 4_000_000
  mFrames <- timeout budgetUs (collect q (optFrames opts) [])
  cancel src
  case mFrames of
    Just fs -> pure (reverse fs)
    Nothing -> hPutStrLn stderr "timed out collecting frames" >> exitFailure
  where
    collect q 0 acc = pure acc
    collect q n acc = do
      f <- atomically (readTBQueue q)
      collect q (n - 1) (f : acc)

-- | One frame through preprocess → infer → decode → NMS → unletterbox
-- → SORT, mirroring 'Hnvr.Cv.Analyzer.analyzeFrame'. Returns the raw
-- (post-NMS, pre-tracker) detections AND the confirmed tracks.
inferFrame :: Analyzer -> (Int, Frame) -> IO (Int, [DetTxt], [Track])
inferFrame an (i, frame) = do
  let cfg = anConfig an
      target = acTargetSize cfg
      lb = letterboxGeometry target target (frameWidth frame) (frameHeight frame)
      tensor = toTensor (preprocessTo target frame)
  out <- infer (anSession an) tensor
  let dets = decode (acConfThreshold cfg) (acKeepClasses cfg) out
      kept = nms (acNmsIou cfg) (acMaxPerClass cfg) dets
      inSource = V.map (unletterboxDetection lb) kept
      tracker' = Sort.update (anTracker an) inSource
  _ <- evaluate tracker'
  let detsTxt = [(cocoClassName (detClassId d), detScore d) | d <- V.toList inSource]
  pure (i, detsTxt, Sort.confirmedTracks tracker')

printRow :: Opts -> FrameRow -> IO ()
printRow _ row =
  hPutStrLn stderr $
    "frame "
      <> show (frIdx row)
      <> " | A: "
      <> show (frDetsA row)
      <> " | B: "
      <> show (frDetsB row)

printSummary :: Opts -> [FrameRow] -> IO ()
printSummary opts rows = do
  hPutStrLn stderr "=== summary ==="
  forM_ [("A", frDetsA, frTracksA), ("B", frDetsB, frTracksB)] $ \(tag, detsF, tracksF) -> do
    let allDets = concatMap detsF rows
        byClass = M.fromListWith (+) [(c, 1 :: Int) | (c, _) <- allDets]
        personScores = [s | ("person", s) <- allDets]
        personFrames = length (filter (any ((== "person") . fst) . detsF) rows)
        maxTracks = maximum (0 : map (length . tracksF) rows)
    hPutStrLn stderr $
      "model "
        <> tag
        <> " ("
        <> (if tag == ("A" :: String) then optModelA opts else optModelB opts)
        <> "):"
    hPutStrLn stderr $ "  detections by class: " <> show (M.toList byClass)
    hPutStrLn stderr $ "  frames with person:  " <> show personFrames <> "/" <> show (length rows)
    unless (null personScores) $
      hPutStrLn stderr $
        "  person conf: avg=" <> show (avg personScores) <> " max=" <> show (maximum personScores)
    hPutStrLn stderr $ "  max confirmed tracks in a frame: " <> show maxTracks
  let disagree =
        [ frIdx row
        | row <- rows,
          let pa = any ((== "person") . fst) (frDetsA row),
          let pb = any ((== "person") . fst) (frDetsB row),
          pa /= pb
        ]
  hPutStrLn stderr $ "person verdict disagreements on frames: " <> show disagree
  where
    avg xs = sum xs / fromIntegral (length xs)

-- | Write one track-annotated PNG per frame per model.
dumpPngs :: [FrameRow] -> FilePath -> IO ()
dumpPngs rows dir = do
  createDirectoryIfMissing True dir
  forM_ rows $ \row -> do
    let pad = reverse (take 4 (reverse (show (frIdx row)) <> repeat '0'))
    BL.writeFile (dir </> ("frame-" <> pad <> "-a.png")) (renderDebugPng (frFrame row) (frTracksA row))
    BL.writeFile (dir </> ("frame-" <> pad <> "-b.png")) (renderDebugPng (frFrame row) (frTracksB row))

-- ---- arg parsing ---------------------------------------------------

parseArgs :: [String] -> Either String Opts
parseArgs args = do
  let (pos, flags) = break (isPrefixOf "--") args
  (url, transport, w, h, fps, mA, mB) <- case pos of
    [u, tr, dims, fpsS, a, b] -> do
      tr' <- parseTransport tr
      (w', h') <- parseDims dims
      fps' <- maybe (Left ("bad fps: " <> fpsS)) Right (readMaybe fpsS)
      pure (u, tr', w', h', fps', a, b)
    _ -> Left "expected 7 positional args: <rtsp-url> <tcp|udp> <WxH> <fps> <modelA> <modelB>"
  (frames, rest1) <- takeFlag flags "--frames" readMaybe
  (pngDir, rest2) <- takeFlag rest1 "--png-dir" Just
  (conf, rest3) <- takeFlag rest2 "--conf" readMaybe
  (scale, rest4) <- takeFlag rest3 "--scale" (either (const Nothing) Just . parseDims)
  unless (null rest4) (Left ("unknown flags: " <> unwords rest4))
  (w', h') <- case scale of
    Just dims -> Right dims
    Nothing -> Right (w, h)
  pure
    Opts
      { optAnalysis =
          AnalysisConfig
            { ancUrl = T.pack url,
              ancTransport = transport,
              ancScale = scale,
              ancFps = fps
            },
        optWidth = w',
        optHeight = h',
        optModelA = mA,
        optModelB = mB,
        optFrames = fromMaybe 20 frames,
        optPngDir = pngDir,
        optConf = fromMaybe 0.10 conf
      }

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
