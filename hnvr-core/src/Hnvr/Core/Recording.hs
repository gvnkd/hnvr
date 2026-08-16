{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Grouping of 1-second fMP4 segment rows into user-facing "recordings".
--
-- The @segments@ table holds one row per fMP4 fragment (~1 s each, so
-- ~86k rows/day/camera). Users think in recordings: maximal runs of
-- consecutive segments. This module is the pure decision logic for the
-- archive browser (extracted from hnvr-web per the S3 pattern so it is
-- cabal-testable — hnvr-web can't be, see MEMORIES pitfall #14).
--
-- A run is split when the gap between the previous segment's @end_ts@
-- and the next segment's @start_ts@ exceeds a caller-supplied tolerance
-- (capture restarts, camera reboots, backoff windows all produce such
-- gaps). Gaps smaller than the split tolerance are surfaced inside the
-- recording via 'recGaps' so the UI can badge "has holes".
module Hnvr.Core.Recording
  ( Span (..),
    Recording (..),
    Gap (..),
    groupRecordings,
    groupRecordingsBy,
    recSegmentCount,
    recBytes,
    recHasAudio,
    recGaps,
    gapDuration,
    formatGap,
    formatRecordingDuration,
  )
where

import Data.List (sortOn)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime)
import Data.UUID (UUID)
import Data.Word (Word64)

-- | Minimal projection of a @segments@ row needed for grouping. The web
-- layer projects IHP @Segment@ records into this shape at the call site.
data Span = Span
  { spCameraId :: !UUID,
    spStart :: !UTCTime,
    spEnd :: !UTCTime,
    spBytes :: !Word64,
    spHasAudio :: !Bool,
    spObjectKey :: !Text,
    -- | Capturing host (segments.host_id). 'Nothing' on rows written
    -- before the column existed / after host removal.
    spHostId :: !(Maybe Text),
    -- | Hex sha256 of the fragment bytes (segments.sha256) — surfaced
    -- in the archive UI for integrity cross-checks against S3.
    spSha256 :: !Text
  }
  deriving stock (Eq, Show)

-- | A hole inside a recording: no segments cover @[gapStart, gapEnd)@.
data Gap = Gap
  { gapStart :: !UTCTime,
    gapEnd :: !UTCTime
  }
  deriving stock (Eq, Show)

-- | A maximal run of consecutive segments. Invariants (enforced by
-- 'groupRecordings'): @recSpans@ is non-empty and sorted by 'spStart';
-- @recStart == spStart (head recSpans)@; @recEnd@ is the maximum
-- 'spEnd' across the run.
data Recording = Recording
  { recStart :: !UTCTime,
    recEnd :: !UTCTime,
    recSpans :: [Span]
  }
  deriving stock (Eq, Show)

-- | Group spans into recordings, one group per camera (or any key).
-- Segments from different cameras interleave at sub-second offsets on a
-- shared timeline, so grouping MUST partition by camera first — the
-- plain 'groupRecordings' is only correct for a single-camera input.
-- Input may be unordered; output is sorted by 'recStart'. Two
-- consecutive (sorted, same-key) spans belong to different recordings
-- iff @spStart next - spEnd prev > splitAfter@.
groupRecordingsBy :: (Ord k) => (Span -> k) -> NominalDiffTime -> [Span] -> [Recording]
groupRecordingsBy key splitAfter spans = go (sortOn (\s -> (key s, spStart s)) spans)
  where
    go [] = []
    go (x : xs) =
      let (run, rest) = collect [x] x xs
       in mkRecording (reverse run) : go rest
    collect run prev (y : ys)
      | key y /= key prev || diffUTCTime (spStart y) (spEnd prev) > splitAfter =
          (run, y : ys)
      | otherwise = collect (y : run) y ys
    collect run _ [] = (run, [])
    mkRecording run =
      Recording
        { recStart = spStart (head run),
          recEnd = maximum (map spEnd run),
          recSpans = run
        }

-- | Single-camera grouping: every span belongs to the same group.
-- Prefer 'groupRecordingsBy' with 'spCameraId' for mixed-camera input.
groupRecordings :: NominalDiffTime -> [Span] -> [Recording]
groupRecordings = groupRecordingsBy spCameraId

recSegmentCount :: Recording -> Int
recSegmentCount = length . recSpans

recBytes :: Recording -> Word64
recBytes = sum . map spBytes . recSpans

recHasAudio :: Recording -> Bool
recHasAudio = any spHasAudio . recSpans

-- | Holes inside a recording: gaps between consecutive spans exceeding
-- @gapMin@ but below the split tolerance used at grouping time.
recGaps :: NominalDiffTime -> Recording -> [Gap]
recGaps gapMin rec = go (recSpans rec)
  where
    go (a : b : rest)
      | diffUTCTime (spStart b) (spEnd a) > gapMin =
          Gap (spEnd a) (spStart b) : go (b : rest)
      | otherwise = go (b : rest)
    go _ = []

gapDuration :: Gap -> NominalDiffTime
gapDuration g = diffUTCTime (gapEnd g) (gapStart g)

-- | @"1m 5s"@ / @"42s"@ — compact human rendering for table badges.
formatGap :: Gap -> Text
formatGap = formatDuration . gapDuration

-- | @"2h 3m"@ / @"15m 4s"@ / @"9s"@ — recording duration rendering.
formatRecordingDuration :: Recording -> Text
formatRecordingDuration r = formatDuration (diffUTCTime (recEnd r) (recStart r))

formatDuration :: NominalDiffTime -> Text
formatDuration dt =
  let total = floor dt :: Int
      (h, rem') = total `divMod` 3600
      (m, s) = rem' `divMod` 60
   in T.intercalate " " $
        [tshow h <> "h" | h > 0]
          <> [tshow m <> "m" | m > 0]
          <> [tshow s <> "s" | s > 0 || (h == 0 && m == 0)]
  where
    tshow = T.pack . show
