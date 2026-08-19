{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Snapshot types for the leader→node initial-state request/reply
-- (M1 of the Phase 1 completion milestones).
--
-- When a node boots, it has no idea which cameras are assigned to it
-- (AssignmentCoordinator only publishes on change, not periodically).
-- The node publishes a request to @hnvr.commands.snapshot.<host>@; the
-- leader replies with a 'CameraSnapshotBatch' containing one
-- 'CameraSnapshot' per camera currently assigned to that host. The node
-- then spawns a 'Hnvr.Capture.Worker.CaptureWorker' for each.
--
-- Defined in @hnvr-core@ so both the leader (@hnvr-web@) and node
-- (@hnvr-web@, since both binaries link it) can share the JSON shape
-- without cyclic dependencies.
module Hnvr.Core.CameraSnapshot
  ( CameraSnapshot (..),
    CameraSnapshotBatch (..),
    PtzSnapshot (..),
    RuleSnapshot (..),
    Transport (..),
    transportToText,
    transportFromText,
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, (.:), (.:?), (.=))
import Data.List (intercalate)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)
import Hnvr.Core.Id (CameraId)

-- | Per-camera transport. Mirrors @Hnvr.Capture.Ffmpeg.Transport@ but
-- defined here so @hnvr-core@ doesn't depend on @hnvr-capture@. The
-- text form is what goes on the wire (lowercase, matches ffmpeg
-- @-rtsp_transport@ flag values).
data Transport = TcpTransport | UdpTransport
  deriving stock (Eq, Show, Enum, Bounded)

transportToText :: Transport -> Text
transportToText TcpTransport = "tcp"
transportToText UdpTransport = "udp"

-- | Parse a transport from text. Accepts the lowercase wire form.
-- Returns 'Nothing' on unknown values; callers should log + default
-- to TCP (the safer choice for LAN RTSP).
transportFromText :: Text -> Maybe Transport
transportFromText "tcp" = Just TcpTransport
transportFromText "udp" = Just UdpTransport
transportFromText _ = Nothing

instance ToJSON Transport where
  toJSON = toJSON . transportToText

instance FromJSON Transport where
  parseJSON v =
    parseJSON v >>= \t ->
      case transportFromText t of
        Just tr -> pure tr
        Nothing ->
          fail $
            "Unknown transport: "
              <> T.unpack t
              <> ". Expected one of: "
              <> intercalate ", " (map (T.unpack . transportToText) [minBound .. maxBound])

-- | Snapshot of one camera row, as sent over the wire from leader to
-- node. The fields are exactly what the CaptureSupervisor needs to
-- spawn a 'Hnvr.Capture.Worker.CaptureWorker' — nothing more.
--
-- @csRtspUrl@ carries the credentials embedded in the URL. The schema
-- also stores @password_enc@ / @password_nonce@ for the future
-- @rtsp_template@ rendering path (M3 in the milestones doc); until
-- that lands, the leader renders the URL at snapshot time and the node
-- gets a ready-to-use string.
--
-- @csRecordAudio@ muxes the camera's audio track (band-passed
-- 60 Hz – 14 kHz, AAC) into the recording fragments. Per
-- @03-capture-and-storage.md@ §3.
--
-- Analysis fields (Phase 3): @csRtspSubUrl@/@csSubWidth@/@csSubHeight@
-- come from the @rtsp_sub_url@/@substream_width@/@substream_height@
-- columns (Probe populates them); @csUseSubstream@ mirrors
-- @use_substream_for_analysis@ — when False (or dims/URL missing),
-- the analyzer falls back to the main-stream relay with a
-- @scale=640:360@ filter (design 03 §2b). @csAnalysisFps@ caps the
-- decode rate via ffmpeg @fps=@.
data CameraSnapshot = CameraSnapshot
  { csId :: !CameraId,
    csSlug :: !Text,
    csRtspUrl :: !Text,
    csTransport :: !Transport,
    csRecordAudio :: !Bool,
    csRtspSubUrl :: !(Maybe Text),
    csUseSubstream :: !Bool,
    csSubWidth :: !(Maybe Int),
    csSubHeight :: !(Maybe Int),
    csAnalysisFps :: !Int,
    -- | Bare model name (e.g. @yolov8n-320@); the receiving host
    -- resolves it to @<model-dir>/<name>.onnx@ (design 04
    -- §"Model: YOLOv8n" — per-camera model override).
    csModelName :: !Text,
    -- | Enabled rules on this camera (Phase 4). Projected into
    -- 'Hnvr.Cv.Rules.Rule' by the receiving host.
    csRules :: ![RuleSnapshot],
    -- | PTZ config (Phase 5). 'Just' when @ptz_enabled@ and the row has
    -- everything a 'Hnvr.Ptz.Controller' needs (host, onvif_port,
    -- credentials, profile token). @psPassword@ is decrypted leader-side
    -- and crosses NATS in plaintext — same exposure class as
    -- @csRtspUrl@, which embeds the same credentials.
    csPtz :: !(Maybe PtzSnapshot)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON CameraSnapshot

-- | Hand-written decoder (not derived): @ptz@ defaults to 'Nothing' so
-- a new node tolerates a pre-Phase-5 leader's payloads (deploy order
-- independence).
instance FromJSON CameraSnapshot where
  parseJSON = withObject "CameraSnapshot" $ \o ->
    CameraSnapshot
      <$> o .: "csId"
      <*> o .: "csSlug"
      <*> o .: "csRtspUrl"
      <*> o .: "csTransport"
      <*> o .: "csRecordAudio"
      <*> o .: "csRtspSubUrl"
      <*> o .: "csUseSubstream"
      <*> o .: "csSubWidth"
      <*> o .: "csSubHeight"
      <*> o .: "csAnalysisFps"
      <*> o .: "csModelName"
      <*> o .: "csRules"
      <*> o .:? "csPtz"

-- | PTZ config for one camera, as sent to the owning host.
data PtzSnapshot = PtzSnapshot
  { psHost :: !Text,
    psOnvifPort :: !Int,
    psUsername :: !Text,
    psPassword :: !Text,
    psProfileToken :: !Text,
    psHomePresetToken :: !(Maybe Text),
    psIdleTimeoutS :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | One rule row as sent over the wire. Geometry stays raw JSONB
-- (line endpoints or polygon per design 06) — the receiving host
-- projects it into the typed 'Hnvr.Cv.Rules.Rule' shape; malformed
-- geometry is dropped there, not here.
data RuleSnapshot = RuleSnapshot
  { rsId :: !Text,
    -- | @line_cross@ | @zone_enter@ | @zone_exit@ | @zone_inside@ | @zone_motion@.
    rsKind :: !Text,
    rsGeometry :: !Value,
    rsClasses :: ![Int],
    rsCooldownMs :: !Int,
    -- | Event-clip config (separated event video store). Clip recording
    -- is enabled for the rule iff 'rsClipRetentionHours' is 'Just'.
    rsClipPrerollSec :: !Int,
    rsClipPostrollSec :: !Int,
    rsClipRetentionHours :: !(Maybe Int)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Wire shape of the snapshot reply. A list so we can extend with
-- metadata (batch sequence number, leader id, etc.) without breaking
-- clients that just want the camera list.
--
-- @csbClaimed@ is the duplicate-worker guard: the leader denies the
-- claim when an external node requests a snapshot for the leader's own
-- host (the leader binary already runs the full node role for it — see
-- @01-architecture.md@ "leader = all of node + leader roles"). A node
-- that receives a denied batch must NOT start its ConfigWatcher or any
-- capture workers; it retries until granted. Old leaders that don't
-- emit the field fail the node's decode, which the node treats as
-- denied (safe direction: idle, never double-record).
data CameraSnapshotBatch = CameraSnapshotBatch
  { csbCameras :: [CameraSnapshot],
    csbClaimed :: !Bool
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON CameraSnapshotBatch where
  toJSON b =
    object
      [ "cameras" .= csbCameras b,
        "claimed" .= csbClaimed b
      ]

instance FromJSON CameraSnapshotBatch where
  parseJSON = withObject "CameraSnapshotBatch" $ \o ->
    CameraSnapshotBatch <$> o .: "cameras" <*> o .: "claimed"
