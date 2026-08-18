{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | PTZ preset management (Phase 5, design 05 §"Preset management").
--
--   * 'PtzPresetsAction'      → @/PtzPresets?ptzCameraId=…@ (list + forms)
--   * 'CreatePtzPresetAction' → @/CreatePtzPreset?ptzCameraId=…@ (POST —
--     request/reply set_preset; the camera-assigned token is stored)
--   * 'GotoPtzPresetAction'   → @/GotoPtzPreset?ptzPresetId=…@ (POST)
--   * 'PurgePtzPresetAction'  → @/PurgePtzPreset?ptzPresetId=…@ (POST —
--     not @Delete*@, pitfall #82)
--   * 'HomePtzPresetAction'   → @/HomePtzPreset?ptzPresetId=…@ (POST —
--     mark home; republishes the assign payload so the owning host
--     learns the new home token)
--
-- All commands travel @hnvr.commands.ptz.\<slug\>@ (no SOAP from the
-- leader — the owning host single-writes to the camera's PTZ service).
module Web.Controller.PtzPresets
  ( PtzPresetsController (..),
  )
where

import Data.Aeson (Value (..), object, (.=))
import Data.IORef (readIORef)
import Data.Maybe (isNothing)
import Data.Text (Text)
import Data.UUID (UUID)
import Generated.Types
import Hnvr.Core.Ptz
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Nats.Subjects (commandPtz)
import Hnvr.Web.Audit (audit)
import Hnvr.Web.Auth ()
import Hnvr.Web.BusRegistry (busRegistry)
import Hnvr.Web.CommandTypes (republishAssign)
import Hnvr.Web.View.PtzPresets.Index
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)
import IHP.ModelSupport (Id' (Id))

data PtzPresetsController
  = PtzPresetsAction {ptzCameraId :: !(Id Camera)}
  | CreatePtzPresetAction {ptzCameraId :: !(Id Camera)}
  | GotoPtzPresetAction {ptzPresetId :: !(Id PtzPreset)}
  | PurgePtzPresetAction {ptzPresetId :: !(Id PtzPreset)}
  | HomePtzPresetAction {ptzPresetId :: !(Id PtzPreset)}
  deriving stock (Eq, Show, Data)

instance AutoRoute PtzPresetsController

instance Controller PtzPresetsController where
  beforeAction = ensureIsUser

  action PtzPresetsAction {ptzCameraId} = do
    camera <- fetch ptzCameraId
    presets <- query @PtzPreset |> filterWhere (#cameraId, camUuid camera) |> orderBy #name |> fetch
    render IndexView {..}
  action CreatePtzPresetAction {ptzCameraId} = do
    camera <- fetch ptzCameraId
    let name = param @Text "preset_name"
    mBus <- liftIO (readIORef busRegistry)
    case (camera.ptzEnabled, camera.assignedHost, mBus) of
      (False, _, _) -> failWith "PTZ is disabled on this camera"
      (_, Nothing, _) -> failWith "Camera is unassigned — no host owns it yet"
      (_, _, Nothing) -> failWith "NATS unavailable"
      (True, Just _, Just bus) -> do
        let msg = PtzCommandMsg (CmdSetPreset (PresetName name)) SrcWebUi (uuidText <$> currentUserUuid) Nothing
        mResp <- liftIO (Bus.requestJson bus (commandPtz camera.slug) msg 8000000)
        case mResp of
          Just (PtzReplyOk (Just (String token))) -> do
            preset <-
              newRecord @PtzPreset
                |> set #cameraId (camUuid camera)
                |> set #name name
                |> set #onvifToken (Just token)
                |> createRecord
            audit currentUserUuid "ptz_preset.create" "ptz_preset" (Just (presetUuid preset)) (Just (object ["slug" .= camera.slug, "name" .= name]))
            if wantsJson
              then renderJson (object ["ok" .= True, "token" .= token, "preset_id" .= uuidText (presetUuid preset)])
              else do
                setSuccessMessage ("Preset saved (token " <> token <> ")")
                redirectTo PtzPresetsAction {ptzCameraId}
          Just (PtzReplyOk _) -> failWith "set_preset: unexpected reply shape"
          Just (PtzReplyError e) -> failWith ("set_preset failed: " <> e)
          Nothing -> failWith "set_preset: no response from owning host (timeout)"
    where
      failWith err =
        if wantsJson
          then renderJson (object ["ok" .= False, "error" .= err])
          else do
            setErrorMessage err
            redirectTo PtzPresetsAction {ptzCameraId}
  action GotoPtzPresetAction {ptzPresetId} = do
    preset <- fetch ptzPresetId
    camera <- fetch (presetCameraId preset)
    case preset.onvifToken of
      Nothing -> setErrorMessage "Preset has no ONVIF token"
      Just token -> do
        mWarn <- publishCmd camera (CmdGotoPreset (PresetToken token)) (uuidText <$> currentUserUuid)
        forM_ mWarn setErrorMessage
        audit currentUserUuid "ptz_preset.goto" "ptz_preset" (Just (presetUuid preset)) (Just (object ["slug" .= camera.slug, "name" .= preset.name]))
        when (isNothing mWarn) (setSuccessMessage ("Going to preset " <> preset.name))
    redirectTo PtzPresetsAction {ptzCameraId = presetCameraId preset}
  action PurgePtzPresetAction {ptzPresetId} = do
    preset <- fetch ptzPresetId
    camera <- fetch (presetCameraId preset)
    forM_ preset.onvifToken $ \token -> do
      mWarn <- publishCmd camera (CmdRemovePreset (PresetToken token)) (uuidText <$> currentUserUuid)
      forM_ mWarn setErrorMessage
    deleteRecord preset
    audit currentUserUuid "ptz_preset.delete" "ptz_preset" (Just (presetUuid preset)) (Just (object ["slug" .= camera.slug, "name" .= preset.name]))
    if wantsJson
      then renderJson (object ["ok" .= True])
      else do
        setSuccessMessage "Preset deleted"
        redirectTo PtzPresetsAction {ptzCameraId = presetCameraId preset}
  action HomePtzPresetAction {ptzPresetId} = do
    preset <- fetch ptzPresetId
    camera <- fetch (presetCameraId preset)
    siblings <- query @PtzPreset |> filterWhere (#cameraId, preset.cameraId) |> fetch
    forM_ siblings $ \p ->
      p |> set #isHome ((p |> get #id) == (preset |> get #id)) |> updateRecord
    camera' <- camera |> set #ptzHomePresetId (Just ptzPresetId) |> updateRecord
    mBus <- liftIO (readIORef busRegistry)
    forM_ mBus $ \bus -> republishAssign bus camera'
    audit currentUserUuid "ptz_preset.home" "ptz_preset" (Just (presetUuid preset)) (Just (object ["slug" .= camera.slug, "name" .= preset.name]))
    setSuccessMessage ("Home preset: " <> preset.name)
    redirectTo PtzPresetsAction {ptzCameraId = presetCameraId preset}

-- | Fire-and-forget command publish (goto/remove). Returns a warning
-- when the command can't reach a host; the caller decides whether the
-- local state change still proceeds.
publishCmd :: Camera -> PtzCommand -> Maybe Text -> IO (Maybe Text)
publishCmd camera cmd mUser = do
  mBus <- readIORef busRegistry
  case (camera.assignedHost, mBus) of
    (Nothing, _) -> pure (Just "camera is unassigned — command not sent")
    (_, Nothing) -> pure (Just "NATS unavailable — command not sent")
    (Just _, Just bus) -> do
      Bus.publishJson bus (commandPtz camera.slug)
        $ PtzCommandMsg cmd SrcWebUi mUser Nothing
      pure Nothing

presetCameraId :: PtzPreset -> Id Camera
presetCameraId preset = Id preset.cameraId

-- | ptz.js passes format=json for fetch-driven row ops (no redirect).
wantsJson :: (?request :: Request) => Bool
wantsJson = paramOrNothing @Text "format" == Just "json"

presetUuid :: PtzPreset -> UUID
presetUuid p = case p |> get #id of Id u -> u

camUuid :: Camera -> UUID
camUuid cam = case cam |> get #id of Id u -> u

uuidText :: UUID -> Text
uuidText = cs . show

currentUserUuid :: (?request :: Request) => Maybe UUID
currentUserUuid = case currentUserOrNothing of
  Nothing -> Nothing
  Just u -> case u |> get #id of Id uuid -> Just uuid
