{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | Domain identifiers used throughout HNVR.
--
-- Defined here so that all sublibraries (capture, cv, ptz, storage, web) share
-- a single canonical type for each ID, avoiding accidental String\/Text mixups
-- at boundaries.
module Hnvr.Core.Id
  ( CameraId(..)
  , RuleId(..)
  , TrackId(..)
  , HostId(..)
  , Sha256(..)
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.ByteString (ByteString)
import Data.String (IsString)
import Data.Text (Text)
import Data.UUID (UUID)

-- | Unique identifier for a configured camera. Stable across renames.
newtype CameraId = CameraId { unCameraId :: UUID }
  deriving newtype
    ( Eq, Ord, Show
    , FromJSON, ToJSON
    )

-- | Unique identifier for a CV rule (line-cross / zone-intrusion).
newtype RuleId = RuleId { unRuleId :: UUID }
  deriving newtype
    ( Eq, Ord, Show
    , FromJSON, ToJSON
    )

-- | Per-camera tracker ID assigned by SORT. Resets on tracker restart.
newtype TrackId = TrackId { unTrackId :: Int }
  deriving newtype
    ( Eq, Ord, Show
    , FromJSON, ToJSON
    , Num, Enum, Real, Integral
    )

-- | Our own NixOS host identifier (e.g. @hnvr-1@, @hnvr-2@).
newtype HostId = HostId { unHostId :: Text }
  deriving newtype
    ( Eq, Ord, Show
    , FromJSON, ToJSON
    , IsString, Semigroup, Monoid
    )

-- | SHA-256 digest of an fMP4 segment, used for SeaweedFS object integrity.
--
-- Stored as raw bytes. JSON serialization (hex-encoded) lands when the
-- segment publisher is wired in Phase 1.
newtype Sha256 = Sha256 { unSha256 :: ByteString }
  deriving newtype
    ( Eq, Ord, Show
    )
