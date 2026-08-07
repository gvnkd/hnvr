{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | PTZ driver abstraction.
--
-- Single instance in v1: 'OnvifPtzDriver'. Adding a vendor-CGI backend later
-- (e.g. for non-ONVIF cameras) is a new instance — no upstream changes.
--
-- See @design_docs/02-tech-stack.md@ ("Driver abstraction").
module Hnvr.Ptz.Driver
  ( Velocity(..)
  , StopAxes(..)
  , PtzStatus(..)
  , PresetToken(..)
  , PresetName(..)
  , PtzDriver(..)
  ) where

import Data.Text (Text)
import GHC.Generics (Generic)
import Hnvr.Core.Geometry (V2)
import Hnvr.Core.Id (CameraId)

-- | Velocity command for @ContinuousMove@. PanTilt components in @[-1, 1]@,
-- zoom in @[-1, 1]@. Camera scales these to its configured speed ranges
-- (queried via @GetConfigurationOptions@).
data Velocity = Velocity
  { vPanTilt :: !(V2 Float)
  , vZoom    :: !Float
  } deriving stock (Eq, Show, Generic)

-- | Which axes to stop on @Stop@.
data StopAxes = StopAxes
  { saPanTilt :: !Bool
  , saZoom    :: !Bool
  } deriving stock (Eq, Show, Generic)

-- | Snapshot of camera position from @GetStatus@.
data PtzStatus = PtzStatus
  { psPanTilt :: !(V2 Float)
  , psZoom    :: !Float
  } deriving stock (Eq, Show, Generic)

newtype PresetToken = PresetToken { unPresetToken :: Text }
  deriving newtype (Eq, Ord, Show)

newtype PresetName = PresetName { unPresetName :: Text }
  deriving newtype (Eq, Ord, Show)

-- | Capability-style driver. Implemented by 'OnvifPtzDriver' in v1.
class Monad m => PtzDriver m where
  continuousMove :: CameraId -> Velocity -> TimeoutMs -> m ()
  stop           :: CameraId -> StopAxes -> m ()
  gotoPreset     :: CameraId -> PresetToken -> m ()
  setPreset      :: CameraId -> PresetName -> m PresetToken
  removePreset   :: CameraId -> PresetToken -> m ()
  getStatus      :: CameraId -> m (Maybe PtzStatus)

type TimeoutMs = Int
