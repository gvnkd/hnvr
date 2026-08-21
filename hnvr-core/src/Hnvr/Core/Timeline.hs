{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure timeline model for the unified archive page
-- (design_docs/12-timeline-archive.md, Phase B).
--
-- The @\/TimelineData@ endpoint projects 'Hnvr.Core.Recording.Span's
-- into per-camera coverage spans and @events@ rows into timeline
-- markers; this module owns the merging/bucketing rules so the web
-- controller stays a thin query-and-render shell. Kept in @hnvr-core@
-- for testability (pitfall #14 extraction pattern).
module Hnvr.Core.Timeline
  ( -- * Response model
    TimelineResponse (..),
    CameraTimeline (..),
    CoverageSpan (..),
    TimelineMarker (..),

    -- * Pure transforms
    coverageSpans,
    bucketMarkers,
    markerCap,
  )
where

import Data.Aeson (ToJSON (..), object, (.=))
import Data.Text (Text)
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime)
import Data.UUID (UUID)
import GHC.Generics (Generic)
import Hnvr.Core.Recording (Recording (..), Span (..), groupRecordingsBy)

-- | One merged coverage interval on a camera's lane.
data CoverageSpan = CoverageSpan
  { csStart :: !UTCTime,
    csEnd :: !UTCTime
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON CoverageSpan where
  toJSON s = object ["start" .= csStart s, "end" .= csEnd s]

-- | One CV event placed on the timeline.
data TimelineMarker = TimelineMarker
  { tmId :: !UUID,
    tmTs :: !UTCTime,
    -- | @event_kind@ enum text (line_crossed, zone_*, …).
    tmKind :: !Text,
    tmRule :: !(Maybe Text),
    tmClipId :: !(Maybe UUID)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON TimelineMarker where
  toJSON m =
    object
      [ "id" .= tmId m,
        "ts" .= tmTs m,
        "kind" .= tmKind m,
        "rule" .= tmRule m,
        "clipId" .= tmClipId m
      ]

-- | One camera's lane: merged coverage + (possibly bucketed) markers.
data CameraTimeline = CameraTimeline
  { ctId :: !UUID,
    ctSlug :: !Text,
    ctSpans :: ![CoverageSpan],
    ctEvents :: ![TimelineMarker],
    -- | 'True' when 'bucketMarkers' dropped markers (the client shows a
    -- "zoom in for more" hint).
    ctTruncated :: !Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON CameraTimeline where
  toJSON c =
    object
      [ "id" .= ctId c,
        "slug" .= ctSlug c,
        "spans" .= ctSpans c,
        "events" .= ctEvents c,
        "truncated" .= ctTruncated c
      ]

-- | Whole @\/TimelineData@ payload.
data TimelineResponse = TimelineResponse
  { trFrom :: !UTCTime,
    trTo :: !UTCTime,
    trCameras :: ![CameraTimeline]
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON TimelineResponse where
  toJSON r =
    object
      [ "from" .= trFrom r,
        "to" .= trTo r,
        "cameras" .= trCameras r
      ]

-- | Merge raw segment spans into coverage intervals. Delegates to
-- 'groupRecordingsBy' keyed on 'spCameraId' (mixed-camera input is
-- safe, pitfall #81; the split tolerance is the caller's choice — the
-- archive browser uses 30 s) and projects each recording to its
-- @(start, end)@.
coverageSpans :: NominalDiffTime -> [Span] -> [CoverageSpan]
coverageSpans splitAfter spans =
  [CoverageSpan (recStart r) (recEnd r) | r <- groupRecordingsBy spCameraId splitAfter spans]

-- | Cap for markers per camera lane. 500 keeps a 24 h window of a busy
-- camera grid responsive without visible thinning (a marker every ~3 min
-- at the cap).
markerCap :: Int
markerCap = 500

-- | Thin a marker list to at most @cap@ entries by time-bucketing:
-- the window is divided into @cap@ equal buckets and each bucket keeps
-- its earliest marker (markers must be sorted ascending by time — the
-- events query orders @ts DESC@, so reverse before calling). Returns
-- the kept markers plus a truncation flag. Single pass, O(n).
--
-- Bucketing (vs. naive @take cap@) keeps the markers spread across the
-- whole window instead of clustering at its start.
bucketMarkers :: Int -> UTCTime -> UTCTime -> [TimelineMarker] -> ([TimelineMarker], Bool)
bucketMarkers cap from to markers
  | length markers <= cap = (markers, False)
  | otherwise = (go (-1) [] markers, True)
  where
    window = max 1 (diffUTCTime to from)
    bucketOf m =
      min (cap - 1) (floor (fromIntegral cap * diffUTCTime (tmTs m) from / window) :: Int)
    -- Ascending ts ⇒ non-decreasing buckets; keep the first marker of
    -- each new bucket.
    go _ acc [] = reverse acc
    go lastB acc (m : ms)
      | bucketOf m == lastB = go lastB acc ms
      | otherwise = go (bucketOf m) (m : acc) ms
