{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Shared wire-payload types + camera→snapshot projection used by
-- 'Hnvr.Web.AssignmentCoordinator' (publisher) and
-- 'Hnvr.Node.ConfigWatcher' (subscriber).
--
-- Kept in its own module so the leader and node sides link against the
-- same JSON shape; before M1 the @AssignMsg@/@ControlMsg@ types were
-- duplicated in their respective modules and carried only slug+host,
-- which forced the node to do an extra round-trip to learn the RTSP
-- URL of a freshly-assigned camera.
module Hnvr.Web.CommandTypes
  ( AssignPayload (..),
    ControlPayload (..),
    SnapshotRequest (..),
    projectCamera,
    projectCameraWithRules,
    cameraIdOf,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import Generated.Types
import Hnvr.Core.CameraSnapshot
  ( CameraSnapshot (..),
    RuleSnapshot (..),
    Transport,
    transportFromText,
  )
import Hnvr.Core.Id (CameraId (..))
import IHP.HaskellSupport (get, (|>))
import IHP.ModelSupport (Id' (Id))

-- | Wire payload for @hnvr.commands.assign.<slug>@.
--
-- @apCamera = Just snap@ when the camera is enabled and the receiving
-- host should spawn a worker for it; 'Nothing' when the camera was
-- disabled or deleted (the receiving host treats this as a stop
-- directive for any worker already running for this slug).
--
-- @apCameraId@ is always populated so subscribers can stop an existing
-- worker by id even when @apCamera@ is 'Nothing'.
data AssignPayload = AssignPayload
  { apSlug :: !Text,
    apHost :: !Text,
    apCameraId :: !UUID,
    apCamera :: !(Maybe CameraSnapshot)
  }
  deriving stock (Eq, Show)

instance ToJSON AssignPayload where
  toJSON p =
    object
      [ "slug" .= p.apSlug,
        "host" .= p.apHost,
        "camera_id" .= p.apCameraId,
        "camera" .= p.apCamera
      ]

instance FromJSON AssignPayload where
  parseJSON = withObject "AssignPayload" $ \o ->
    AssignPayload
      <$> o .: "slug"
      <*> o .: "host"
      <*> o .: "camera_id"
      <*> o .: "camera"

-- | Wire payload for @hnvr.commands.control.<host>.<slug>.<action>@.
-- Carries the 'CameraId' so the receiving host can stop the right
-- worker without an extra snapshot round-trip (the worker map is keyed
-- by 'CameraId', not slug).
data ControlPayload = ControlPayload
  { cpSlug :: !Text,
    cpAction :: !Text,
    cpCameraId :: !UUID
  }
  deriving stock (Eq, Show)

instance ToJSON ControlPayload where
  toJSON p =
    object
      [ "slug" .= p.cpSlug,
        "action" .= p.cpAction,
        "camera_id" .= p.cpCameraId
      ]

instance FromJSON ControlPayload where
  parseJSON = withObject "ControlPayload" $ \o ->
    ControlPayload
      <$> o .: "slug"
      <*> o .: "action"
      <*> o .: "camera_id"

-- | Wire payload for @hnvr.commands.snapshot.<host>@ request body.
-- Currently empty (the host id is in the subject); kept as a record so
-- we can add fields like @since@ (sequence number) without breaking
-- clients.
newtype SnapshotRequest = SnapshotRequest
  { srHost :: Text
  }
  deriving stock (Eq, Show)

instance ToJSON SnapshotRequest where
  toJSON r = object ["host" .= r.srHost]

instance FromJSON SnapshotRequest where
  parseJSON = withObject "SnapshotRequest" $ \o ->
    SnapshotRequest <$> o .: "host"

-- | Project an IHP @Camera@ record into the worker-ready
-- 'CameraSnapshot'. Returns 'Nothing' when:
--   * the camera is disabled (@enabled = False@), OR
--   * the @rtsp_transport@ column has a value we don't recognise
--     (we log + treat as disabled rather than spawning a worker that
--     will immediately fail at ffmpeg SETUP).
projectCamera :: Camera -> Maybe CameraSnapshot
projectCamera = projectCameraWithRules []

-- | 'projectCamera' with the camera's rules attached (Phase 4: rule
-- CRUD republishes the assign payload so the owning host restarts the
-- analysis pair with fresh rules).
projectCameraWithRules :: [RuleSnapshot] -> Camera -> Maybe CameraSnapshot
projectCameraWithRules rules cam =
  if not cam.enabled
    then Nothing
    else case transportFromText cam.rtspTransport of
      Nothing -> Nothing
      Just tr ->
        Just
          CameraSnapshot
            { csId = cameraIdOf cam,
              csSlug = cam.slug,
              csRtspUrl = cam.rtspUrl,
              csTransport = tr,
              csRecordAudio = cam.recordAudio,
              csRtspSubUrl = cam.rtspSubUrl,
              csUseSubstream = cam.useSubstreamForAnalysis,
              csSubWidth = fromIntegral <$> cam.substreamWidth,
              csSubHeight = fromIntegral <$> cam.substreamHeight,
              csAnalysisFps = fromIntegral cam.analysisFps,
              csRules = rules
            }

-- | Unwrap the IHP @Id' "cameras"@ newtype into the underlying 'UUID'
-- so it can travel over the wire as a plain JSON string. Pattern match
-- on the 'Id' constructor (per pitfall #39 — there's no
-- @ConvertibleStrings@ instance, and 'Data.Coerce.coerce' fails with
-- the constructor out of scope).
cameraIdOf :: Camera -> CameraId
cameraIdOf cam =
  case cam |> get #id of
    Id uuid -> CameraId uuid
