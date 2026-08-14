{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | CV event wire type (Phase 4). Published by analyzer hosts on
-- @hnvr.events@ alongside 'Hnvr.Core.Segment.SegmentWritten'; the
-- leader's EventWriter decodes it into the @events@ table (design 06).
--
-- Distinct envelope from SegmentWritten — EventWriter tries
-- SegmentWritten first, then this. bbox is normalized 0..1 source
-- coords (resolution-independent, per Hnvr.Core.Geometry docs).
module Hnvr.Core.Event
  ( CvEvent (..),
  )
where

import Data.Aeson (FromJSON, ToJSON, Value)
import Data.Text (Text)
import Data.Time.Clock (UTCTime)
import GHC.Generics (Generic)
import Hnvr.Core.Id (CameraId, HostId)

-- | One CV event on the wire. @ceRuleId@ is the rules-table UUID as
-- text ('Nothing' for track-lifecycle events, Phase 4b).
data CvEvent = CvEvent
  { ceCamera :: !CameraId,
    ceRuleId :: !(Maybe Text),
    ceTs :: !UTCTime,
    -- | @line_crossed@ | @zone_enter@ | @zone_exit@ | @zone_inside@ —
    -- matches the @event_kind@ PG enum text.
    ceKind :: !Text,
    ceClassId :: !(Maybe Int),
    ceTrackId :: !(Maybe Int),
    ceConfidence :: !(Maybe Double),
    -- | Normalized bbox {x,y,w,h} as raw JSON (matches events.bbox).
    ceBbox :: !(Maybe Value),
    -- | S3 key of the bbox-overlaid frame PNG
    -- (@<slug>/events/<YYYY-MM-DD/HH-MM-SS.mmm>.png@); 'Nothing' when
    -- S3 was unreachable at event time.
    ceThumbnailKey :: !(Maybe Text),
    ceHost :: !HostId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
