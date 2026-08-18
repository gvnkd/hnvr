{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | PTZ command endpoint (Phase 5, design 05 §"PTZ control").
--
--   * @PtzCameraAction@       → @POST /PtzCamera?ptzCameraId=…@ — relay
--     one command to the owning host via @hnvr.commands.ptz.\<slug\>@.
--     @set_preset@/@get_presets@ use request/reply (caller needs the
--     camera's answer); the rest are fire-and-forget.
--   * @PtzStatusCameraAction@ → @GET /PtzStatusCamera?ptzCameraId=…@ —
--     latest status broadcast from the owning host (1 Hz UI poll).
--
-- Audit rows are written from the node's @hnvr.ptz.audit@ feed by
-- 'Hnvr.Web.PtzAuditWriter' (execution, not publish intent).
module Web.Controller.Ptz
  ( PtzController (..),
  )
where

import Data.Aeson (Value, object, (.=))
import Data.IORef (readIORef)
import Data.Text (Text)
import Data.UUID (UUID)
import Generated.Types
import Hnvr.Core.Ptz
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Nats.Subjects (commandPtz)
import Hnvr.Web.Auth ()
import Hnvr.Web.BusRegistry (busRegistry)
import Hnvr.Web.PtzStatusCache (latestPtzStatus)
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)
import IHP.ModelSupport (Id' (Id))

data PtzController
  = PtzCameraAction {ptzCameraId :: !(Id Camera)}
  | PtzStatusCameraAction {ptzCameraId :: !(Id Camera)}
  deriving stock (Eq, Show, Data)

instance AutoRoute PtzController

instance Controller PtzController where
  beforeAction = ensureIsUser

  action PtzCameraAction {ptzCameraId} = do
    camera <- fetch ptzCameraId
    if not camera.ptzEnabled
      then renderJson (errJson "ptz disabled on this camera")
      else do
        mBus <- liftIO (readIORef busRegistry)
        case mBus of
          Nothing -> renderJson (errJson "NATS unavailable")
          Just bus -> case decodeCommand of
            Left err -> renderJson (errJson err)
            Right cmd -> do
              let msg =
                    PtzCommandMsg
                      { pcmCommand = cmd,
                        pcmSource = SrcWebUi,
                        pcmUserId = uuidText <$> currentUserUuid,
                        pcmDurationMs = durationMs
                      }
                  subject = commandPtz camera.slug
              if needsReply cmd
                then do
                  mResp <- liftIO (Bus.requestJson bus subject msg 8000000)
                  case mResp of
                    Nothing -> renderJson (errJson "no response from owning host (timeout)")
                    Just (PtzReplyError e) -> renderJson (errJson e)
                    Just (PtzReplyOk v) -> renderJson (object ["ok" .= True, "result" .= v])
                else do
                  liftIO (Bus.publishJson bus subject msg)
                  renderJson (object ["ok" .= True])
  action PtzStatusCameraAction {ptzCameraId} = do
    camera <- fetch ptzCameraId
    mStatus <- liftIO (latestPtzStatus camera.slug)
    case mStatus of
      Just st -> renderJson (object ["ok" .= True, "status" .= st])
      Nothing -> renderJson (object ["ok" .= False, "error" .= ("no status yet" :: Text)])

errJson :: Text -> Value
errJson e = object ["ok" .= False, "error" .= e]

-- | Commands whose camera answer the caller needs.
needsReply :: PtzCommand -> Bool
needsReply CmdSetPreset {} = True
needsReply CmdGetPresets = True
needsReply _ = False

uuidText :: UUID -> Text
uuidText = cs . show

currentUserUuid :: (?request :: Request) => Maybe UUID
currentUserUuid = case currentUserOrNothing of
  Nothing -> Nothing
  Just u -> case u |> get #id of Id uuid -> Just uuid

durationMs :: (?request :: Request) => Maybe Int
durationMs = paramOrNothing @Int "duration_ms"

-- | Decode the command from request params. Strict: missing/malformed
-- args are an error, never a silent no-op.
decodeCommand :: (?request :: Request) => Either Text PtzCommand
decodeCommand = case paramOrNothing @Text "command" of
  Just "continuous_move" ->
    CmdContinuousMove
      <$> (Velocity <$> reqF "vx" <*> reqF "vy" <*> reqF "zoom")
      <*> Right (paramOrNothing @Int "timeout_ms")
  Just "stop" ->
    Right
      $ CmdStop
        ( StopAxes
            (axisOn "pan_tilt")
            (axisOn "zoom_stop")
        )
  Just "goto_preset" -> CmdGotoPreset . PresetToken <$> reqT "preset_token"
  Just "set_preset" -> CmdSetPreset . PresetName <$> reqT "preset_name"
  Just "remove_preset" -> CmdRemovePreset . PresetToken <$> reqT "preset_token"
  Just "go_home" -> Right CmdGoHome
  Just "absolute_move" ->
    CmdAbsoluteMove <$> (PtzPosition <$> reqF "x" <*> reqF "y" <*> reqF "zoom")
  Just "get_presets" -> Right CmdGetPresets
  Just other -> Left ("unknown ptz command: " <> other)
  Nothing -> Left "missing command param"
  where
    reqT name = maybe (Left ("missing param: " <> cs name)) Right (paramOrNothing @Text name)
    reqF name = maybe (Left ("missing param: " <> cs name)) (Right . realToFrac) (paramOrNothing @Double name)
    axisOn name = paramOrNothing @Text name /= Just "false"
