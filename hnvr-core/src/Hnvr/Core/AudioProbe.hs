{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Measuring a camera's TRUE audio sampling rate when the database
-- has no opinion.
--
-- Background (see "Hnvr.Core.CameraSnapshot" 'audioInputRateHz' and
-- the v0.15 archive fix in @Hnvr.Capture.Ffmpeg@): Hik-OEM cameras
-- sample G.711 at 16 kHz but clock PCMU\/PCMA RTP at a fixed 8 kHz
-- (RFC 3551 fixes the G.711 clock), so every receiver that trusts the
-- SDP decodes a 2x-slowed, one-octave-lowered stream. The archive
-- pipeline corrects it with an @asetrate@ retag fed from the DB
-- (@cameras.audio_sample_rate_khz@); when that column is NULL the
-- rate can be MEASURED from the stream itself:
--
--   * payload bytes arrive at the true sample production rate (one
--     byte per sample for PCMU\/PCMA, half a byte for G.726), while
--   * RTP timestamps advance at (true \/ declared) times wall speed,
--     so any media-time math just reproduces the declared 8000 —
--     only wall-clock arrival times carry the signal.
--
-- The probe fits a least-squares slope of cumulative payload bytes
-- against packet ARRIVAL time over a few seconds (robust against the
-- connect burst, which only lifts the intercept) and buckets the
-- result to the nearest standard rate. A retag is proposed only when
-- the measured rate is >= 1.5x the declared clock — the quirk is an
-- integer oversample in practice (16 kHz over an 8 kHz clock), and
-- the ratio guard keeps a burst-inflated misread from ever producing
-- a near-miss asetrate.
module Hnvr.Core.AudioProbe
  ( -- * Probe plumbing
    codecProbeArgs,
    packetProbeArgs,
    parseCodecFields,
    ProbedAudio (..),

    -- * Codec facts
    isFixedClockCodec,
    bitsPerSample,

    -- * Rate math
    trueRateHz,
    nearestRateHz,
    quirkAsetrateHz,
  )
where

import Data.Char (isDigit)
import Data.List (foldl')
import Data.Text (Text)
import qualified Data.Text as T

-- | ffprobe argv that prints the audio track's codec and declared
-- sample rate. On a live RTSP source ffprobe exits after the initial
-- probe, so this is cheap; csv=p=0 emits @<codec>,<rate>@ (or the
-- reverse — 'parseCodecFields' is order-agnostic).
codecProbeArgs :: Text -> [String]
codecProbeArgs url =
  [ "-v",
    "error",
    "-rtsp_transport",
    "tcp",
    "-select_streams",
    "a:0",
    "-show_entries",
    "stream=codec_name,sample_rate",
    "-of",
    "csv=p=0",
    T.unpack url
  ]

-- | ffprobe argv that streams one @<pts_time>,<size>@ line per audio
-- packet and never exits on a live source — the caller reads for a
-- bounded window and kills the process.
packetProbeArgs :: Text -> [String]
packetProbeArgs url =
  [ "-v",
    "error",
    "-rtsp_transport",
    "tcp",
    "-select_streams",
    "a:0",
    "-show_entries",
    "packet=size,pts_time",
    "-of",
    "csv=p=0",
    T.unpack url
  ]

-- | Result of a full probe: what the stream declares and, when the
-- fixed-clock quirk was confirmed and measurable, the @asetrate@
-- value that corrects it.
data ProbedAudio = ProbedAudio
  { paCodec :: !Text,
    paDeclaredHz :: !Int,
    paAsetrateHz :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

-- | Parse one csv line from 'codecProbeArgs' into (codec, declared
-- Hz). Field order is not guaranteed across ffprobe builds, so the
-- all-digits field is the rate.
parseCodecFields :: Text -> Maybe (Text, Int)
parseCodecFields line =
  case map T.strip (T.splitOn "," line) of
    [a, b]
      | T.all isDigit b, not (T.null b) -> Just (a, read (T.unpack b))
      | T.all isDigit a, not (T.null a) -> Just (b, read (T.unpack a))
    _ -> Nothing

-- | Codecs whose RTP clock is pinned at 8 kHz whatever the camera
-- samples at (the RFC 3551 G.711 rule and G.726's usual deployment).
-- These are the only codecs where an @asetrate@ retag is ever valid —
-- AAC et al. carry their true rate in the SDP and must NOT be
-- retagged.
isFixedClockCodec :: Text -> Bool
isFixedClockCodec c = c `elem` ["pcm_mulaw", "pcm_alaw", "g726"]

-- | Payload bits per sample: 8 for PCMU\/PCMA, 4 for G.726. Converts
-- measured bytes\/s into samples\/s.
bitsPerSample :: Text -> Maybe Int
bitsPerSample "g726" = Just 4
bitsPerSample c | c `elem` ["pcm_mulaw", "pcm_alaw"] = Just 8
bitsPerSample _ = Nothing

-- | Standard audio rates to snap a noisy measurement onto.
rateBuckets :: [Int]
rateBuckets = [8000, 11025, 16000, 22050, 24000, 32000, 44100, 48000]

-- | Snap a measured rate to the nearest standard rate, if it is
-- within 30% of one. 'Nothing' for out-of-family measurements.
nearestRateHz :: Int -> Maybe Int
nearestRateHz r
  | r < 4000 || r > 96000 = Nothing
  | otherwise = case foldl' closer (Nothing, maxBound) rateBuckets of
      (Just c, _) | abs (c - r) <= c * 3 `div` 10 -> Just c
      _ -> Nothing
  where
    closer (mbest, dbest) c =
      let d = abs (c - r)
       in if d < dbest then (Just c, d) else (mbest, dbest)

-- | Least-squares slope of cumulative payload bytes against arrival
-- time, converted to samples\/s via 'bitsPerSample' and snapped with
-- 'nearestRateHz'. Points are @(seconds since probe start, packet
-- size)@; the caller should already have dropped the warmup window.
-- Needs a >= 1 s span and >= 10 packets — shorter windows carry too
-- much scheduling jitter to trust.
trueRateHz :: Int -> [(Double, Int)] -> Maybe Int
trueRateHz bits pts
  | bits <= 0 = Nothing
  | n < 10 = Nothing
  | spanT < 1 = Nothing
  | var == 0 = Nothing
  | otherwise = nearestRateHz (round (slope * fromIntegral (8 `div` bits)))
  where
    n = length pts
    cum = scanl1 (+) (map snd pts)
    xs = map fst pts
    ys = map fromIntegral cum :: [Double]
    spanT = last xs - head xs
    sx = sum xs
    sy = sum ys
    sxx = sum (zipWith (*) xs xs)
    sxy = sum (zipWith (*) xs ys)
    var = fromIntegral n * sxx - sx * sx
    slope = (fromIntegral n * sxy - sx * sy) / var

-- | The retag value for the @asetrate@ filter: the measured rate only
-- when it is decisively above the declared clock (>= 1.5x). Below
-- that the camera is honest and retagging would corrupt pitch.
quirkAsetrateHz :: Int -> Int -> Maybe Int
quirkAsetrateHz declaredHz measuredHz
  | measuredHz * 2 >= declaredHz * 3 = Just measuredHz
  | otherwise = Nothing
