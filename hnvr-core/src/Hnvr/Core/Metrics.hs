{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Metrics handle + Prometheus text renderer.
--
-- The 'Metrics' record is a bag of IO actions so the instrumented
-- packages (hnvr-capture, hnvr-cv) don't need an ekg-core dependency —
-- they call actions; hnvr-web backs them with an ekg-core 'Store'
-- ("Hnvr.Web.Metrics"). Tests and binaries that don't care pass
-- 'noOpMetrics'.
--
-- 'renderPrometheus' is pure so it can be cabal-tested from hnvr-core
-- (pitfall #14 extraction pattern): hnvr-web samples the ekg store
-- into @[(Text, MetricSample)]@ and hands it here.
--
-- Label encoding: ekg-core has no label concept, so label sets are
-- embedded in the metric name itself (@hnvr_frames_decoded_total{camera=\"floor_2_5\"}@)
-- and the renderer splits at the first @{@ when emitting distribution
-- suffixes (@_count@\/@_sum@\/@_max@ go before the label brace, per
-- Prometheus exposition rules).
module Hnvr.Core.Metrics
  ( Metrics (..),
    noOpMetrics,
    MetricSample (..),
    DistStats (..),
    renderPrometheus,
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T

-- | Bag of instrumentation actions. All must be cheap and non-blocking
-- (ekg counter increments are atomic CAS); called from the hot frame
-- path (every decoded frame, every inference).
data Metrics = Metrics
  { -- | One frame decoded by the analysis ffmpeg. Arg: camera slug.
    mFrameDecoded :: !(Text -> IO ()),
    -- | One frame evicted by the drop-oldest queue. Arg: camera slug.
    mFrameDropped :: !(Text -> IO ()),
    -- | One completed per-frame CV pipeline run. Args: EP name
    -- (@cpu@\/@cuda@\/@tensorrt@), wall seconds.
    mRecordInference :: !(Text -> Double -> IO ()),
    -- | Analysis fell back to relay main-stream-with-scale for a
    -- camera. Arg: camera slug.
    mSubstreamFallback :: !(Text -> IO ())
  }

noOpMetrics :: Metrics
noOpMetrics =
  Metrics
    { mFrameDecoded = \_ -> pure (),
      mFrameDropped = \_ -> pure (),
      mRecordInference = \_ _ -> pure (),
      mSubstreamFallback = \_ -> pure ()
    }

-- | Distribution statistics snapshot (mirror of ekg-core's
-- @System.Metrics.Distribution.Internal.Stats@ — duplicated here so
-- hnvr-core stays ekg-free).
data DistStats = DistStats
  { dsMean :: !Double,
    dsVariance :: !Double,
    dsCount :: !Int64,
    dsSum :: !Double,
    dsMin :: !Double,
    dsMax :: !Double
  }
  deriving stock (Eq, Show)

-- | One sampled metric. Names may carry an embedded Prometheus label
-- set (everything from the first @{@ on is treated as labels).
data MetricSample
  = SCounter !Int64
  | SGauge !Int64
  | SDist !DistStats
  deriving stock (Eq, Show)

-- | Render samples in Prometheus text exposition format (v0.0.4).
-- Output order follows the input order; callers that want stable
-- diffs should sort by name first. Distributions expand to
-- @_count@\/@_sum@ lines only — ekg-core's striped 'combine' copies
-- min\/max from the last stripe unconditionally (untouched stripes
-- stay 0.0), so @_max@ would be garbage under @-N@. Average latency
-- is @rate(_sum) \/ rate(_count)@, which is the Prometheus-idiomatic
-- shape anyway.
renderPrometheus :: [(Text, MetricSample)] -> Text
renderPrometheus samples = T.intercalate "\n" (concatMap render samples) <> "\n"
  where
    render (name, SCounter n) = [name <> " " <> tshow n]
    render (name, SGauge n) = [name <> " " <> tshow n]
    render (name, SDist st) =
      let (base, labels) = splitLabels name
          suffix s = base <> s <> labels
       in [ suffix "_count" <> " " <> tshow (dsCount st),
            suffix "_sum" <> " " <> dshow (dsSum st)
          ]

    -- Split "base{a=\"b\"}" into ("base", "{a=\"b\"}"); no brace →
    -- labels is empty.
    splitLabels :: Text -> (Text, Text)
    splitLabels name =
      let (base, rest) = T.break (== '{') name
       in (base, rest)

    tshow :: Int64 -> Text
    tshow = T.pack . show

    -- Prometheus accepts Go-style float formatting; 'show' on Double
    -- is close enough (scientific notation is legal in exposition).
    dshow :: Double -> Text
    dshow = T.pack . show
