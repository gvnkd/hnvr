{-# LANGUAGE DerivingStrategies #-}

-- | A decoded video frame for the analysis path.
--
-- Produced by the analysis ffmpeg (sub-stream decode, Phase 3
-- AnalyzerWorker) and consumed by "Hnvr.Cv.Preprocess". Kept in
-- hnvr-core so hnvr-capture (producer) and hnvr-cv (consumer) both
-- depend on it without a capture→cv dependency.
--
-- Pixels are RGB24, row-major, tightly packed (@width*height*3@
-- bytes). No up-front downscale: sub-stream frames arrive at native
-- resolution; the main-stream-with-scale fallback arrives at 640×360
-- via ffmpeg's @-vf scale@ — same code path either way
-- (design_docs/04-cv-pipeline.md §1).
module Hnvr.Core.Frame
  ( Frame (..),
  )
where

import Data.Time.Clock (UTCTime)
import qualified Data.Vector.Storable as VS
import Data.Word (Word8)

data Frame = Frame
  { frameWidth :: !Int,
    frameHeight :: !Int,
    -- | Wall-clock capture time (used for event timestamps).
    frameTimestamp :: !UTCTime,
    -- | @width*height*3@ bytes, RGB24 row-major.
    frameRgb :: !(VS.Vector Word8)
  }
  deriving stock (Eq, Show)
