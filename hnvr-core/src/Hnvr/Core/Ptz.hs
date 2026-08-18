{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

-- | PTZ wire types + pure state machine (Phase 5, design 01
-- §"NATS subjects" / 06 §"PTZ presets" / 08 Phase 5).
--
-- Everything here is pure and cabal-tested; the SOAP client lives in
-- @Hnvr.Onvif.Client@ (hnvr-ptz), the per-camera IO glue in
-- @Hnvr.Ptz.Controller@ (hnvr-ptz), the leader-side publishers in
-- @Web.Controller.Ptz@ (hnvr-web).
--
-- Wire protocol:
--
--   * @hnvr.commands.ptz.\<slug\>@ carries a 'PtzCommandMsg'. When the
--     publisher needs a result (set_preset token, preset list) it uses
--     request/reply; the controller answers with a 'PtzReply'.
--   * @hnvr.ptz.status.\<slug\>@ carries a 'PtzStatusMsg' after every
--     executed command (live UI indicator).
--   * @hnvr.ptz.audit@ carries a 'PtzAuditRecord' for every executed
--     command; the leader-side @Hnvr.Web.PtzAuditWriter@ persists rows
--     (nodes have no DB access).
module Hnvr.Core.Ptz
  ( -- * Shared value types
    Velocity (..),
    StopAxes (..),
    PtzPosition (..),
    PresetToken (..),
    PresetName (..),

    -- * Commands (UI/leader → owning host)
    PtzCommand (..),
    PtzSource (..),
    PtzCommandMsg (..),
    commandName,
    commandArgs,
    ptzSourceText,
    ptzSourceFromText,

    -- * Replies (owning host → requester)
    PtzReply (..),
    OnvifPreset (..),

    -- * Status (owning host → all)
    PtzState (..),
    PtzStatusMsg (..),
    ptzStateText,
    stateAfter,

    -- * Audit (owning host → leader)
    PtzAuditRecord (..),
  )
where

import Data.Aeson (FromJSON (..), Object, ToJSON (..), Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

-- | Velocity command for @ContinuousMove@. All components in @[-1, 1]@;
-- the camera scales them to its configured speed ranges.
data Velocity = Velocity
  { vPan :: !Float,
    vTilt :: !Float,
    vZoom :: !Float
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON Velocity where
  toJSON v = object ["vx" .= vPan v, "vy" .= vTilt v, "zoom" .= vZoom v]

instance FromJSON Velocity where
  parseJSON = withObject "Velocity" $ \o ->
    Velocity <$> o .: "vx" <*> o .: "vy" <*> o .: "zoom"

-- | Which axes to stop on @Stop@.
data StopAxes = StopAxes
  { saPanTilt :: !Bool,
    saZoom :: !Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | A pan/tilt/zoom position (absolute-move target or GetStatus
-- readout). Components in @[-1, 1]@ (ONVIF generic spaces).
data PtzPosition = PtzPosition
  { ppPan :: !Float,
    ppTilt :: !Float,
    ppZoom :: !Float
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

newtype PresetToken = PresetToken {unPresetToken :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

newtype PresetName = PresetName {unPresetName :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (ToJSON, FromJSON)

-- | One preset as reported by the camera (GetPresets).
data OnvifPreset = OnvifPreset
  { opToken :: !PresetToken,
    opName :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Who issued a PTZ command. Wire values match the @ptz_source@ PG
-- enum exactly so audit rows insert without a translation layer.
data PtzSource = SrcWebUi | SrcAutoTrack | SrcIdleTimeout | SrcApi | SrcSchedule
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

ptzSourceText :: PtzSource -> Text
ptzSourceText SrcWebUi = "web_ui"
ptzSourceText SrcAutoTrack = "auto_track"
ptzSourceText SrcIdleTimeout = "idle_timeout"
ptzSourceText SrcApi = "api"
ptzSourceText SrcSchedule = "schedule"

ptzSourceFromText :: Text -> Maybe PtzSource
ptzSourceFromText t = lookup t [(ptzSourceText s, s) | s <- [minBound .. maxBound]]

instance ToJSON PtzSource where
  toJSON = toJSON . ptzSourceText

instance FromJSON PtzSource where
  parseJSON v = parseJSON v >>= \t -> maybe (fail ("unknown ptz source: " <> T.unpack t)) pure (ptzSourceFromText t)

-- | One PTZ operation. @CmdGoHome@ is resolved by the controller to a
-- @GotoPreset@ on the camera's configured home preset (or an
-- @AbsoluteMove@ to the origin when no home preset is set).
data PtzCommand
  = CmdContinuousMove !Velocity !(Maybe Int)
  | CmdStop !StopAxes
  | CmdGotoPreset !PresetToken
  | CmdSetPreset !PresetName
  | CmdRemovePreset !PresetToken
  | CmdGoHome
  | CmdAbsoluteMove !PtzPosition
  | CmdGetPresets
  deriving stock (Eq, Show, Generic)

-- | Stable command names (audit rows, metrics labels, wire tag).
commandName :: PtzCommand -> Text
commandName CmdContinuousMove {} = "continuous_move"
commandName CmdStop {} = "stop"
commandName CmdGotoPreset {} = "goto_preset"
commandName CmdSetPreset {} = "set_preset"
commandName CmdRemovePreset {} = "remove_preset"
commandName CmdGoHome = "go_home"
commandName CmdAbsoluteMove {} = "absolute_move"
commandName CmdGetPresets = "get_presets"

-- | JSON args blob for audit rows (@{vx,vy,zoom}@ / @{preset_token}@ /
-- ...). Matches design 06 §"PTZ audit log".
commandArgs :: PtzCommand -> Value
commandArgs (CmdContinuousMove v toMs) =
  object ["vx" .= vPan v, "vy" .= vTilt v, "zoom" .= vZoom v, "timeout_ms" .= toMs]
commandArgs (CmdStop a) = object ["pan_tilt" .= saPanTilt a, "zoom" .= saZoom a]
commandArgs (CmdGotoPreset t) = object ["preset_token" .= t]
commandArgs (CmdSetPreset n) = object ["preset_name" .= n]
commandArgs (CmdRemovePreset t) = object ["preset_token" .= t]
commandArgs CmdGoHome = object []
commandArgs (CmdAbsoluteMove p) = toJSON p
commandArgs CmdGetPresets = object []

-- | Command envelope on @hnvr.commands.ptz.\<slug\>@.
data PtzCommandMsg = PtzCommandMsg
  { pcmCommand :: !PtzCommand,
    pcmSource :: !PtzSource,
    -- | Acting user's UUID text (audit); 'Nothing' = system-initiated.
    pcmUserId :: !(Maybe Text),
    -- | Joystick hold duration for continuous_move (audit column).
    pcmDurationMs :: !(Maybe Int)
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON PtzCommandMsg where
  toJSON m =
    object
      [ "command" .= commandName (pcmCommand m),
        "args" .= commandArgs (pcmCommand m),
        "source" .= pcmSource m,
        "user_id" .= pcmUserId m,
        "duration_ms" .= pcmDurationMs m
      ]

instance FromJSON PtzCommandMsg where
  parseJSON = withObject "PtzCommandMsg" $ \o -> do
    name <- o .: "command"
    cmd <- parseCommand name (o .: "args")
    PtzCommandMsg cmd
      <$> o .: "source"
      <*> o .:? "user_id"
      <*> o .:? "duration_ms"

-- | Strict command decode: unknown names and malformed args are
-- rejected (a typo'd command must not silently no-op).
parseCommand :: Text -> Parser Value -> Parser PtzCommand
parseCommand name argsP = case name of
  "continuous_move" -> withObj $ \o -> CmdContinuousMove <$> parseVelocity o <*> o .:? "timeout_ms"
  "stop" -> withObj $ \o -> CmdStop <$> (StopAxes <$> o .: "pan_tilt" <*> o .: "zoom")
  "goto_preset" -> withObj $ \o -> CmdGotoPreset <$> o .: "preset_token"
  "set_preset" -> withObj $ \o -> CmdSetPreset <$> o .: "preset_name"
  "remove_preset" -> withObj $ \o -> CmdRemovePreset <$> o .: "preset_token"
  "go_home" -> pure CmdGoHome
  "absolute_move" -> withObj $ \o -> fmap CmdAbsoluteMove (parseJSON' o)
  "get_presets" -> pure CmdGetPresets
  other -> fail ("unknown ptz command: " <> T.unpack other)
  where
    withObj :: (Object -> Parser a) -> Parser a
    withObj f = argsP >>= withObject "PtzCommand.args" f
    parseVelocity o = Velocity <$> o .: "vx" <*> o .: "vy" <*> o .: "zoom"
    parseJSON' = parseJSON . toJSON

-- | Reply to a request/reply PTZ command. @set_preset@ replies carry
-- the camera-assigned token; @get_presets@ the full list.
data PtzReply
  = PtzReplyOk !(Maybe Value)
  | PtzReplyError !Text
  deriving stock (Eq, Show, Generic)

instance ToJSON PtzReply where
  toJSON (PtzReplyOk v) = object ["ok" .= True, "result" .= v]
  toJSON (PtzReplyError e) = object ["ok" .= False, "error" .= e]

instance FromJSON PtzReply where
  parseJSON = withObject "PtzReply" $ \o -> do
    ok <- o .: "ok"
    if ok then PtzReplyOk <$> o .:? "result" else PtzReplyError <$> o .: "error"

-- | Controller state machine (design: @Hnvr.Ptz.Controller@ diagram).
-- v1 has no AutoTracking (Phase 7).
data PtzState = PtzIdle | PtzManualMove | PtzGoingToPreset | PtzReturningHome
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

ptzStateText :: PtzState -> Text
ptzStateText PtzIdle = "idle"
ptzStateText PtzManualMove = "manual_move"
ptzStateText PtzGoingToPreset = "going_to_preset"
ptzStateText PtzReturningHome = "returning_home"

-- | State after successfully issuing a command. @stop@ settles to
-- idle; moves/preset jumps are fire-and-forget in v1 (consumer
-- firmware doesn't reliably report move completion), so the status
-- reverts to idle on the NEXT command or status tick rather than
-- tracking arrival.
stateAfter :: PtzCommand -> PtzState
stateAfter CmdContinuousMove {} = PtzManualMove
stateAfter CmdStop {} = PtzIdle
stateAfter CmdGotoPreset {} = PtzGoingToPreset
stateAfter CmdGoHome = PtzReturningHome
stateAfter _ = PtzIdle

-- | Status broadcast on @hnvr.ptz.status.\<slug\>@ after every executed
-- command. Position is a best-effort readout ('Nothing' when the camera
-- reports a nil status — fixed cameras answer PTZ ops without moving).
data PtzStatusMsg = PtzStatusMsg
  { psmState :: !PtzState,
    psmPosition :: !(Maybe PtzPosition),
    psmLastCommand :: !Text,
    psmLastCommandAt :: !Text
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON PtzStatusMsg where
  toJSON m =
    object
      [ "state" .= ptzStateText (psmState m),
        "position" .= psmPosition m,
        "last_command" .= psmLastCommand m,
        "last_command_at" .= psmLastCommandAt m
      ]

instance FromJSON PtzStatusMsg where
  parseJSON = withObject "PtzStatusMsg" $ \o -> do
    st <- o .: "state"
    s <- maybe (fail ("unknown ptz state: " <> T.unpack st)) pure (lookup st stateTable)
    PtzStatusMsg s <$> o .:? "position" <*> o .: "last_command" <*> o .: "last_command_at"
    where
      stateTable = [(ptzStateText s, s) | s <- [minBound .. maxBound]]

-- | One executed command, node → leader on @hnvr.ptz.audit@. Persisted
-- verbatim into @ptz_audit_log@ by the leader-side writer.
data PtzAuditRecord = PtzAuditRecord
  { parCameraId :: !Text,
    parUserId :: !(Maybe Text),
    parCommand :: !Text,
    parArgs :: !Value,
    parSource :: !PtzSource,
    parDurationMs :: !(Maybe Int),
    parOk :: !Bool,
    parError :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)
