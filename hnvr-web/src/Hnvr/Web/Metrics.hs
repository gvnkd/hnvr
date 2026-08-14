{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | ekg-core backed metrics + Prometheus text endpoint.
--
-- 'ensureMetrics' hands out the process-global ('Store', 'Metrics')
-- pair (created on first call — same unsafePerformIO-IORef pattern as
-- "Hnvr.Web.SupervisorRegistry", because the consumers are created in
-- IHP initializers / mains where plumbing a handle through would mean
-- threading it across module boundaries that don't otherwise know
-- about metrics).
--
-- 'startMetricsServer' serves the store in Prometheus text exposition
-- format on @HNVR_METRICS_PORT@ (default 9100) via a dedicated warp —
-- deliberately NOT through the IHP middleware chain (pitfall #60
-- first-write-wins, auth gating, and the node binary has no HTTP
-- server at all). Both @hnvr-leader@ and @hnvr-node@ run it.
--
-- Metric names embed their Prometheus label sets directly
-- (@hnvr_frames_decoded_total{camera=\"floor_2_5\"}@) because ekg-core
-- has no label concept; "Hnvr.Core.Metrics.renderPrometheus" splits at
-- the brace when emitting distribution suffixes.
module Hnvr.Web.Metrics
  ( ensureMetrics,
    startMetricsServer,
    startGpuPoller,
  )
where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar (modifyMVar, newMVar)
import Control.Exception (SomeException, try)
import Control.Monad (forM_, forever, void)
import qualified Data.ByteString.Lazy.Char8 as LBS
import qualified Data.HashMap.Strict as HM
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Int (Int64)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Hnvr.Core.Logging (logInfo)
import Hnvr.Core.Metrics
  ( DistStats (..),
    MetricSample (..),
    Metrics (..),
    renderPrometheus,
  )
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai
import qualified Network.Wai.Handler.Warp as Warp
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)
import System.Metrics
  ( Store,
    Value (..),
    createCounter,
    createDistribution,
    createGauge,
    newStore,
    sampleAll,
  )
import qualified System.Metrics.Counter as Counter
import qualified System.Metrics.Distribution as Dist
import qualified System.Metrics.Distribution.Internal as DistI
import qualified System.Metrics.Gauge as Gauge
import qualified System.Process.Typed as Proc
import Text.Read (readMaybe)

{-# NOINLINE globalMetrics #-}
globalMetrics :: IORef (Maybe (Store, Metrics))
globalMetrics = unsafePerformIO (newIORef Nothing)

-- | The process-global ('Store', 'Metrics') pair, creating it on first
-- call. Single-threaded at every call site (process boot), so the
-- check-then-set race is theoretical.
ensureMetrics :: IO (Store, Metrics)
ensureMetrics = do
  cached <- readIORef globalMetrics
  case cached of
    Just sm -> pure sm
    Nothing -> do
      store <- newStore
      metrics <- newMetrics store
      writeIORef globalMetrics (Just (store, metrics))
      pure (store, metrics)

-- | Build the 'Metrics' action bag over a store. Per-camera counters
-- and per-EP distributions are created lazily and cached (ekg-core
-- errors on duplicate registration, so the cache is load-bearing).
newMetrics :: Store -> IO Metrics
newMetrics store = do
  counters <- newMVar Map.empty
  dists <- newMVar Map.empty
  let counter name = modifyMVar counters $ \m ->
        case Map.lookup name m of
          Just c -> pure (m, c)
          Nothing -> do
            c <- createCounter name store
            pure (Map.insert name c m, c)
      dist name = modifyMVar dists $ \m ->
        case Map.lookup name m of
          Just d -> pure (m, d)
          Nothing -> do
            d <- createDistribution name store
            pure (Map.insert name d m, d)
  pure
    Metrics
      { mFrameDecoded = \slug ->
          counter ("hnvr_frames_decoded_total{camera=\"" <> slug <> "\"}") >>= Counter.inc,
        mFrameDropped = \slug ->
          counter ("hnvr_frames_dropped_total{camera=\"" <> slug <> "\"}") >>= Counter.inc,
        mRecordInference = \ep secs ->
          dist ("hnvr_inference_seconds{ep=\"" <> ep <> "\"}") >>= \d -> Dist.add d secs,
        mSubstreamFallback = \slug ->
          counter ("hnvr_substream_fallback_total{camera=\"" <> slug <> "\"}") >>= Counter.inc
      }

-- | Serve @GET \/metrics@ in Prometheus text format on
-- @HNVR_METRICS_PORT@ (default 9100). Forks a warp thread and returns.
startMetricsServer :: Store -> IO ()
startMetricsServer store = do
  port <- fromMaybe 9100 . (>>= readMaybe) <$> lookupEnv "HNVR_METRICS_PORT"
  _ <- forkIO (Warp.run port app)
  logInfo ("metrics: Prometheus endpoint on :" <> T.pack (show port) <> "/metrics")
  where
    app req respond
      | Wai.rawPathInfo req == "/metrics" = do
          sample <- sampleAll store
          let samples = mapMaybe convert (HM.toList sample)
              body = renderPrometheus samples
          respond $
            Wai.responseLBS
              HTTP.status200
              [("Content-Type", "text/plain; version=0.0.4; charset=utf-8")]
              (LBS.fromStrict (TE.encodeUtf8 body))
      | otherwise =
          respond (Wai.responseLBS HTTP.status404 [] "not found")

    convert (name, v) = case v of
      Counter n -> Just (name, SCounter n)
      Gauge n -> Just (name, SGauge n)
      Distribution st ->
        Just
          ( name,
            SDist
              DistStats
                { dsMean = DistI.mean st,
                  dsVariance = DistI.variance st,
                  dsCount = DistI.count st,
                  dsSum = DistI.sum st,
                  dsMin = DistI.min st,
                  dsMax = DistI.max st
                }
          )
      Label _ -> Nothing

-- | Poll @nvidia-smi@ every 15 s and publish
-- @hnvr_gpu_memory_used_bytes@ (sum across GPUs) plus the process's
-- own RSS (@hnvr_process_resident_bytes@, from /proc/self/statm) —
-- the leak-watch metric. Silent when nvidia-smi is absent or fails
-- (CPU-only hosts) — the gauges just stay at 0.
startGpuPoller :: Store -> IO ()
startGpuPoller store = do
  gauge <- createGauge "hnvr_gpu_memory_used_bytes" store
  rssGauge <- createGauge "hnvr_process_resident_bytes" store
  _ <- forkIO $ forever $ do
    r <-
      try
        ( snd
            <$> Proc.readProcessStdout
              (Proc.proc "nvidia-smi" ["--query-gpu=memory.used", "--format=csv,noheader,nounits"])
        ) ::
        IO (Either SomeException LBS.ByteString)
    case r of
      Left _ -> pure ()
      Right out ->
        let mib = sum (mapMaybe (readMaybe . LBS.unpack) (LBS.lines out))
         in Gauge.set gauge (round (mib * 1024 * 1024))
    rss <- readRssBytes
    forM_ rss (Gauge.set rssGauge)
    threadDelay 15_000_000
  pure ()
  where
    -- statm field 2 is resident pages.
    readRssBytes :: IO (Maybe Int64)
    readRssBytes = do
      r <- try (readFile "/proc/self/statm") :: IO (Either SomeException String)
      pure $ case r of
        Left _ -> Nothing
        Right s ->
          case words s of
            (_ : pages : _) ->
              let pagesN = read pages :: Integer
               in Just (fromIntegral (pagesN * 4096))
            _ -> Nothing
