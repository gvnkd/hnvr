{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | The 'Segment' type and its lightweight JSON envelope 'SegmentWritten'.
--
-- 'Segment' is the in-flight type carried inside the capture pipeline:
-- it owns the fMP4 bytes. 'SegmentWritten' is what we publish on NATS
-- subject @hnvr.events@ — bytes are stripped, replaced by a length and
-- the resolved SeaweedFS object key, so subscribers (the leader's
-- EventWriter) don't need to re-fetch the bytes to insert the row.
module Hnvr.Core.Segment
  ( Segment (..),
    SegmentKind (..),
    SegmentWritten (..),
    toSegmentWritten,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Text (Text)
import Data.Word (Word64)
import GHC.Generics (Generic)
import Hnvr.Core.Id (CameraId, HostId, Sha256)
import Hnvr.Core.Prelude (UTCTime)

-- | One 1-second fMP4 fragment captured from a camera.
data Segment = Segment
  { sCamera :: !CameraId,
    sSlug :: !Text,
    sStart :: !UTCTime,
    sEnd :: !UTCTime,
    sBytes :: !ByteString,
    sSha :: !Sha256,
    sKind :: !SegmentKind,
    sHostId :: !HostId
  }
  deriving stock (Eq, Show, Generic)

-- | Whether the segment carries video or muxed audio.
data SegmentKind = Video | Audio
  deriving stock (Eq, Show, Generic, Enum, Bounded)
  deriving anyclass (ToJSON, FromJSON)

-- | Event payload published on @hnvr.events@ with kind @segment_written@.
data SegmentWritten = SegmentWritten
  { swCamera :: !CameraId,
    swSlug :: !Text,
    swStart :: !UTCTime,
    swEnd :: !UTCTime,
    swBytes :: !Word64,
    swSha :: !Sha256,
    swKind :: !SegmentKind,
    swHostId :: !HostId,
    swObjectKey :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Project a 'Segment' into its 'SegmentWritten' envelope. The object
-- key is supplied by the caller: the capture worker computes it with
-- millisecond precision ('Hnvr.Core.Time.formatSegmentObjectKeyMs') at
-- upload time, and recomputing it here at second precision would make
-- the published key diverge from the uploaded object (pitfall #25 —
-- HEVC cameras emit 2+ fragments per wall-clock second).
toSegmentWritten :: Text -> Segment -> SegmentWritten
toSegmentWritten objectKey s =
  SegmentWritten
    { swCamera = sCamera s,
      swSlug = sSlug s,
      swStart = sStart s,
      swEnd = sEnd s,
      swBytes = fromIntegral (B.length (sBytes s)),
      swSha = sSha s,
      swKind = sKind s,
      swHostId = sHostId s,
      swObjectKey = objectKey
    }
