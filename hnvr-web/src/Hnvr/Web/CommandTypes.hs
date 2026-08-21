{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImplicitParams #-}
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
    ptzSnapshotFor,
    republishAssign,
    republishAssignAlways,
    publishAssignTo,
    cameraIdOf,
  )
where

import Control.Monad (forM_)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import qualified Data.UUID as UUID
-- Generated.Types gained a CameraSnapshot row type (camera_snapshots
-- table, migration 0013) which collides with the wire type below —
-- the row type is unused here.
import Generated.Types hiding (CameraSnapshot)
import Hnvr.Core.CameraSnapshot
  ( CameraSnapshot (..),
    PtzSnapshot (..),
    RuleSnapshot (..),
    Transport,
    transportFromText,
  )
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Core.Onvif (hostFromRtspUrl)
import Hnvr.Nats.Bus (Bus)
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Nats.Subjects (commandAssign)
import IHP.Fetch (fetch, fetchOneOrNothing)
import IHP.HaskellSupport (get, (|>))
import IHP.ModelSupport (Id' (Id), ModelContext)
import IHP.QueryBuilder (filterWhere, query)
import Web.Controller.Support.Crypto (decryptPassword)

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
--
-- IO since Phase 5: the PTZ projection decrypts the camera password.
projectCamera :: (?modelContext :: ModelContext) => Camera -> IO (Maybe CameraSnapshot)
projectCamera = projectCameraWithRules []

-- | 'projectCamera' with the camera's rules attached (Phase 4: rule
-- CRUD republishes the assign payload so the owning host restarts the
-- analysis pair with fresh rules).
projectCameraWithRules :: (?modelContext :: ModelContext) => [RuleSnapshot] -> Camera -> IO (Maybe CameraSnapshot)
projectCameraWithRules rules cam =
  if not cam.enabled
    then pure Nothing
    else case transportFromText cam.rtspTransport of
      Nothing -> pure Nothing
      Just tr -> do
        ptz <- ptzSnapshotFor cam
        pure $
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
                csSnapshotIntervalSec = fromIntegral cam.snapshotIntervalSec,
                csModelName = cam.modelName,
                csRules = rules,
                csPtz = ptz
              }

-- | Build the PTZ snapshot for a camera row (Phase 5). 'Nothing'
-- unless @ptz_enabled@ AND every required piece is present:
--   * management protocol is ONVIF (DVRIP rows can't PTZ via ONVIF),
--   * host (falls back to the RTSP URL authority, same as
--     'Hnvr.Web.OnvifSync.targetForCamera'),
--   * @onvif_port@, @username@, decryptable password, and a probed
--     @ptz_profile_token@.
-- The home preset's ONVIF token is resolved with one query when
-- @ptz_home_preset_id@ is set.
ptzSnapshotFor :: (?modelContext :: ModelContext) => Camera -> IO (Maybe PtzSnapshot)
ptzSnapshotFor cam
  | not cam.ptzEnabled = pure Nothing
  | cam.mgmtProto /= "onvif" = pure Nothing
  | otherwise = case (mHost, cam.onvifPort, nonEmpty cam.username, cam.ptzProfileToken) of
      (Just host', Just port', Just user, Just profileToken) -> do
        mPw <- decryptPassword cam.passwordEnc cam.passwordNonce
        case mPw of
          Nothing -> pure Nothing
          Just pw -> do
            homeToken <- homePresetToken
            pure $
              Just
                PtzSnapshot
                  { psHost = host',
                    psOnvifPort = fromIntegral port',
                    psUsername = user,
                    psPassword = pw,
                    psProfileToken = profileToken,
                    psHomePresetToken = homeToken,
                    psIdleTimeoutS = fromIntegral cam.ptzIdleTimeoutS
                  }
      _ -> pure Nothing
  where
    mHost = case cam.host of
      Just h | not (T.null h) -> Just h
      _ -> hostFromRtspUrl cam.rtspUrl
    nonEmpty (Just t) | not (T.null t) = Just t
    nonEmpty _ = Nothing
    homePresetToken = case cam.ptzHomePresetId of
      Nothing -> pure Nothing
      Just pid -> do
        mPreset <- query @PtzPreset |> filterWhere (#id, pid) |> fetchOneOrNothing
        pure (mPreset >>= (.onvifToken))

-- | Republish the camera's assign payload (full projection: rules +
-- PTZ) so the owning host restarts its worker pair with fresh config.
-- Shared by rule CRUD (Phase 4) and PTZ preset/config changes
-- (Phase 5). No-op when the camera is unassigned; the caller checks
-- bus availability (boot snapshot covers the next restart either way).
republishAssign :: (?modelContext :: ModelContext) => Bus -> Camera -> IO ()
republishAssign bus camera =
  forM_ camera.assignedHost $ \host -> do
    rules <- query @Rule |> filterWhere (#cameraId, camUuid) |> filterWhere (#enabled, True) |> fetch
    mSnap <- projectCameraWithRules (map ruleSnapOf rules) camera
    forM_ mSnap $ \snap -> publishAssignTo bus camera host (Just snap)
  where
    camUuid = case cameraIdOf camera of CameraId u -> u

-- | 'republishAssign' variant for enable/disable toggles: publishes
-- even when the camera is DISABLED, with @apCamera = Nothing@ — the
-- node's ConfigWatcher reads that as a stop directive. Plain
-- 'republishAssign' would silently skip the publish and the node
-- would keep recording a disabled camera.
republishAssignAlways :: (?modelContext :: ModelContext) => Bus -> Camera -> IO ()
republishAssignAlways bus camera =
  forM_ camera.assignedHost $ \host -> do
    rules <- query @Rule |> filterWhere (#cameraId, camUuid) |> filterWhere (#enabled, True) |> fetch
    mSnap <- projectCameraWithRules (map ruleSnapOf rules) camera
    publishAssignTo bus camera host mSnap
  where
    camUuid = case cameraIdOf camera of CameraId u -> u

publishAssignTo :: Bus -> Camera -> Text -> Maybe CameraSnapshot -> IO ()
publishAssignTo bus camera host mSnap =
  Bus.publishJson bus (commandAssign camera.slug) $
    AssignPayload
      { apSlug = camera.slug,
        apHost = host,
        apCameraId = camUuid,
        apCamera = mSnap
      }
  where
    camUuid = case cameraIdOf camera of CameraId u -> u

ruleSnapOf :: Rule -> RuleSnapshot
ruleSnapOf rule =
  RuleSnapshot
    { rsId = ruleIdText rule,
      rsKind = kindText rule.kind,
      rsGeometry = rule.geometry,
      rsClasses = rule.classes,
      rsCooldownMs = rule.cooldownMs,
      rsClipPrerollSec = rule.clipPrerollSec,
      rsClipPostrollSec = rule.clipPostrollSec,
      rsClipRetentionHours = rule.clipRetentionHours
    }
  where
    ruleIdText r = case r |> get #id of Id u -> UUID.toText u

kindText :: RuleKind -> Text
kindText LineCross = "line_cross"
kindText RuleKindZoneEnter = "zone_enter"
kindText RuleKindZoneExit = "zone_exit"
kindText RuleKindZoneInside = "zone_inside"
kindText RuleKindZoneMotion = "zone_motion"

-- | Unwrap the IHP @Id' "cameras"@ newtype into the underlying 'UUID'
-- so it can travel over the wire as a plain JSON string. Pattern match
-- on the 'Id' constructor (per pitfall #39 — there's no
-- @ConvertibleStrings@ instance, and 'Data.Coerce.coerce' fails with
-- the constructor out of scope).
cameraIdOf :: Camera -> CameraId
cameraIdOf cam =
  case cam |> get #id of
    Id uuid -> CameraId uuid
