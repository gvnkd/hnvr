{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Per-camera capture-status wire format + UI status resolution.
--
-- The capture worker's state machine ("Hnvr.Capture.Worker") used to be
-- log-only: a dead camera kept its stale analysis frame on the
-- dashboard and its static REC badge, and nothing could tell. This
-- module defines the cross-process contract that fixes that:
--
--   * 'CaptureStateWire' — the stable Text encoding of a worker state,
--     carried in the @hnvr.health.<host>@ payload's @cameras@ array
--     ('CameraHealth'). Timestamps/backoff counts are deliberately
--     dropped: consumers only need the phase.
--   * 'resolveCameraStatus' — pure projection from (camera enabled,
--     assigned host view) to the single 'CameraStatus' the web UI
--     renders as REC / RECONNECTING / HOST DOWN / etc.
--
-- Lives in hnvr-core so the encoding (hnvr-capture), the publisher
-- (hnvr-web HealthReporter) and the consumer (hnvr-web views) share
-- one definition, and the resolution table is cabal-testable (hnvr-web
-- itself is nix-build-only, pitfall #14).
module Hnvr.Core.CameraStatus
  ( -- * Wire format
    CaptureStateWire (..),
    captureStateWireToText,
    captureStateWireFromText,
    CameraHealth (..),
    cameraHealthFromPayload,

    -- * UI status resolution
    HostView (..),
    CameraStatus (..),
    resolveCameraStatus,
  )
where

import Data.Aeson
  ( FromJSON (..),
    ToJSON (..),
    Value,
    object,
    withObject,
    (.:),
    (.=),
  )
import Data.Aeson.Types (parseMaybe)
import Data.Maybe (fromMaybe)
import Data.Text (Text)

-- | Phase-only projection of @Hnvr.Capture.Worker.CaptureState@.
data CaptureStateWire
  = WPending
  | WRunning
  | WBackoff
  | WFailed
  | WStopped
  deriving stock (Eq, Show, Enum, Bounded)

captureStateWireToText :: CaptureStateWire -> Text
captureStateWireToText = \case
  WPending -> "pending"
  WRunning -> "running"
  WBackoff -> "backoff"
  WFailed -> "failed"
  WStopped -> "stopped"

captureStateWireFromText :: Text -> Maybe CaptureStateWire
captureStateWireFromText = \case
  "pending" -> Just WPending
  "running" -> Just WRunning
  "backoff" -> Just WBackoff
  "failed" -> Just WFailed
  "stopped" -> Just WStopped
  _ -> Nothing

-- | One camera's entry in the health payload's @cameras@ array:
-- @{"slug": "backyard", "state": "running"}@.
data CameraHealth = CameraHealth
  { chSlug :: !Text,
    chState :: !CaptureStateWire
  }
  deriving stock (Eq, Show)

instance ToJSON CameraHealth where
  toJSON ch =
    object
      [ "slug" .= ch.chSlug,
        "state" .= captureStateWireToText ch.chState
      ]

instance FromJSON CameraHealth where
  parseJSON = withObject "CameraHealth" $ \o -> do
    slug <- o .: "slug"
    stateTxt <- o .: "state"
    case captureStateWireFromText stateTxt of
      Just st -> pure (CameraHealth slug st)
      Nothing -> fail ("unknown capture state: " <> show stateTxt)

-- | Extract the @cameras@ array from a host health payload (the JSON
-- blob stored in @hosts.health_json@). Tolerant: any shape mismatch
-- yields an empty list (treated as \"no camera states reported\").
cameraHealthFromPayload :: Value -> [CameraHealth]
cameraHealthFromPayload v =
  fromMaybe [] (parseMaybe (withObject "Health" (.: "cameras")) v)

-- | What the UI needs to know about a camera's assigned host.
data HostView = HostView
  { -- | @last_health_at@ within the staleness window (15 s, matching
    -- the AssignmentCoordinator timeout).
    hvHeartbeatFresh :: !Bool,
    -- | The camera's entry in the host's payload. 'Nothing' = the
    -- host is reporting but has no worker for this camera.
    hvCameraState :: !(Maybe CaptureStateWire)
  }
  deriving stock (Eq, Show)

-- | Resolved per-camera status — one constructor per UI badge.
data CameraStatus
  = -- | worker Running — the only state that may show REC
    CSRecording
  | -- | worker Pending (ffmpeg spawn in flight)
    CSStarting
  | -- | worker Backoff (ffmpeg exited, retry pending)
    CSReconnecting
  | -- | worker FailedPermanent
    CSFailed
  | -- | assigned host's heartbeat is stale or the host row is gone
    CSHostDown
  | -- | host is healthy but reports no worker for this camera
    CSNotRunning
  | -- | no assigned host
    CSUnassigned
  | -- | cameras.enabled = false
    CSDisabled
  deriving stock (Eq, Show)

-- | Resolution order matters: disabled wins over everything (a
-- disabled camera may still have a stale worker entry); unassigned
-- next; host freshness before trusting the payload.
resolveCameraStatus :: Bool -> Maybe HostView -> CameraStatus
resolveCameraStatus enabled mHost
  | not enabled = CSDisabled
  | otherwise =
      case mHost of
        Nothing -> CSUnassigned
        Just hv
          | not hv.hvHeartbeatFresh -> CSHostDown
          | otherwise ->
              case hv.hvCameraState of
                Nothing -> CSNotRunning
                Just WRunning -> CSRecording
                Just WPending -> CSStarting
                Just WBackoff -> CSReconnecting
                Just WFailed -> CSFailed
                Just WStopped -> CSNotRunning
