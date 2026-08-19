{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Cameras CRUD + ffprobe + admin assignment. IHP-canonical constructor
-- names so AutoRoute generates non-colliding URLs:
--
--   * @CamerasAction@        → @/Cameras@
--   * @ShowCameraAction@     → @/ShowCamera?cameraId=…@
--   * @NewCameraAction@      → @/NewCamera@
--   * @EditCameraAction@     → @/EditCamera?cameraId=…@
--   * @CreateCameraAction@   → @/CreateCamera@ (POST)
--   * @UpdateCameraAction@   → @/UpdateCamera?cameraId=…@ (POST/PATCH)
--   * @DeleteCameraAction@   → @/DeleteCamera?cameraId=…@ (DELETE)
--   * @ProbeCameraAction@    → @/ProbeCamera?cameraId=…@ (POST)
--   * @ProbePtzCameraAction@ → @/ProbePtzCamera?cameraId=…@ (POST)
--   * @AssignCameraAction@   → @/AssignCamera?cameraId=…@ (POST)
module Web.Controller.Cameras
  ( CamerasController (..),
  )
where

import Data.Aeson (object, (.=))
import Data.IORef (readIORef)
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Time.Clock (getCurrentTime)
import Data.UUID (UUID)
import Generated.Types
import Hnvr.Web.Audit (audit)
import Hnvr.Web.Auth ()
import Hnvr.Web.BusRegistry (busRegistry)
import Hnvr.Web.CommandTypes (publishAssignTo, republishAssignAlways)
import Hnvr.Web.OnvifSync (FormOptions, checkCameraDrift, fetchFormOptions, probePtz, pushCameraConfig, targetForCamera)
import Hnvr.Web.OnvifSyncer (persistDrift)
import Hnvr.Web.View.Cameras.Edit
import Hnvr.Web.View.Cameras.Index
import Hnvr.Web.View.Cameras.New
import Hnvr.Web.View.Cameras.Show
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)
import IHP.ModelSupport (Id' (Id))
import qualified Network.HTTP.Client as HC
import Web.Controller.Cameras.Probe (ProbeInfo (..), probe)
import Web.Controller.Support.Crypto (decryptPassword, encryptPassword)

-- | Raw UUID of a camera row (audit targets).
camUuid :: Camera -> UUID
camUuid cam = case cam |> get #id of Id u -> u

-- | Best-effort ONVIF push after Save Changes: Nothing when the camera
-- is ONVIF-unmanaged (no port/host/creds — plain save), otherwise the
-- push result. On a successful push, re-reads the camera and refreshes
-- its camera_drift rows so the badge reflects the push immediately
-- rather than at the next OnvifSyncer tick.
pushOnvif :: Camera -> IO (Maybe (Either Text Text))
pushOnvif cam = do
  eTarget <- targetForCamera cam
  case eTarget of
    Left _ -> pure Nothing
    Right target -> do
      mgr <- HC.newManager HC.defaultManagerSettings
      res <- pushCameraConfig mgr target cam
      case res of
        Right _ -> do
          eDrift <- checkCameraDrift mgr target cam
          case eDrift of
            Right items -> persistDrift (camUuid cam) items
            Left _ -> pure ()
        Left _ -> pure ()
      pure (Just res)

-- | Fetch live ONVIF capabilities for the Edit form dropdowns.
-- 'Nothing' when the camera is unmanaged or unreachable — the form
-- falls back to free-text inputs.
fetchOpts :: Camera -> IO (Maybe FormOptions)
fetchOpts cam = do
  eTarget <- targetForCamera cam
  case eTarget of
    Left _ -> pure Nothing
    Right target -> do
      mgr <- HC.newManager HC.defaultManagerSettings
      Just <$> fetchFormOptions mgr target

-- | Acting user's UUID for audit rows.
currentUserUuid :: (?request :: Request) => Maybe UUID
currentUserUuid = case currentUserOrNothing of
  Nothing -> Nothing
  Just u -> case u |> get #id of Id uuid -> Just uuid

data CamerasController
  = CamerasAction
  | ShowCameraAction {cameraId :: !(Id Camera)}
  | NewCameraAction
  | EditCameraAction {cameraId :: !(Id Camera)}
  | CreateCameraAction
  | UpdateCameraAction {cameraId :: !(Id Camera)}
  | DeleteCameraAction {cameraId :: !(Id Camera)}
  | ToggleCameraEnabledAction {cameraId :: !(Id Camera)}
  | ProbeCameraAction {cameraId :: !(Id Camera)}
  | ProbePtzCameraAction {cameraId :: !(Id Camera)}
  | AssignCameraAction {cameraId :: !(Id Camera)}
  | TestCryptoCameraAction {cameraId :: !(Id Camera)}
  deriving stock (Eq, Show, Data)

instance AutoRoute CamerasController

instance Controller CamerasController where
  beforeAction = ensureIsUser
  action CamerasAction = do
    cameras <- query @Camera |> orderByDesc #createdAt |> fetch
    drifts <- query @CameraDrift |> fetch
    render IndexView {..}
  action ShowCameraAction {cameraId} = do
    camera <- fetch cameraId
    drifts <- query @CameraDrift |> filterWhere (#cameraId, camUuid camera) |> fetch
    hosts <- query @Host |> fetch
    now <- liftIO getCurrentTime
    render ShowView {..}
  action NewCameraAction = do
    -- newRecord defaults analysisFps to 0, which violates the form's
    -- min="1" and makes HTML5 validation silently block every submit.
    -- Default to the documented 5 fps (design 03 §2b).
    let camera = newRecord @Camera |> set #analysisFps 5
    render NewView {..}
  action EditCameraAction {cameraId} = do
    camera <- fetch cameraId
    formOptions <- liftIO (fetchOpts camera)
    render EditView {..}
  action CreateCameraAction = do
    let camera0 =
          newRecord @Camera
            |> fill @'["slug", "name", "rtspUrl", "rtspTransport", "host", "username", "rtspSubUrl", "analysisFps", "modelName", "retentionHours"]
        plaintext = paramOrDefault ("" :: Text) "password"
    (enc, nonce) <- liftIO (encryptPassword plaintext)
    let camera =
          camera0
            |> set #passwordEnc (Just enc)
            |> set #passwordNonce (Just nonce)
            |> set #enabled (checkboxOn "enabled")
            |> set #recordAudio (checkboxOn "recordAudio")
            |> set #useSubstreamForAnalysis (checkboxOn "useSubstreamForAnalysis")
    if camera |> isValid
      then do
        camera <- camera |> createRecord
        audit currentUserUuid "camera.create" "camera" (Just (camUuid camera)) (Just (object ["slug" .= camera.slug]))
        setSuccessMessage "Camera created"
        redirectTo ShowCameraAction {cameraId = camera |> get #id}
      else render NewView {..}
    where
      checkboxOn name = paramOrNothing @Text name == Just "on"
  action UpdateCameraAction {cameraId} = do
    camera <- fetch cameraId
    let camera' =
          camera
            |> fill @'["slug", "name", "rtspUrl", "rtspTransport", "host", "username", "rtspSubUrl", "analysisFps", "modelName", "retentionHours", "onvifPort", "mgmtProto", "mainVideoEncoding", "mainVideoWidth", "mainVideoHeight", "mainVideoFps", "mainVideoBitrateKbps", "mainVideoGovLength", "subVideoEncoding", "subVideoWidth", "subVideoHeight", "subVideoFps", "subVideoBitrateKbps", "subVideoGovLength", "audioEncoding", "audioBitrateKbps", "audioSampleRateKhz", "ptzProfileToken", "ptzIdleTimeoutS"]
        plaintext = paramOrNothing "password" :: Maybe Text
    now <- liftIO getCurrentTime
    camera'' <- case plaintext of
      Nothing -> pure camera'
      Just "" -> pure camera'
      Just pw -> do
        (enc, nonce) <- liftIO (encryptPassword pw)
        pure
          ( camera'
              |> set #passwordEnc (Just enc)
              |> set #passwordNonce (Just nonce)
          )
    let camera2 =
          camera''
            |> set #enabled (checkboxOn "enabled")
            |> set #recordAudio (checkboxOn "recordAudio")
            |> set #useSubstreamForAnalysis (checkboxOn "useSubstreamForAnalysis")
            |> set #ptzEnabled (checkboxOn "ptzEnabled")
            |> set #ptzViewerControl (checkboxOn "ptzViewerControl")
            |> set #updatedAt now
    if camera2 |> isValid
      then do
        camera''' <- camera2 |> updateRecord
        audit currentUserUuid "camera.update" "camera" (Just (camUuid camera''')) (Just (object ["slug" .= camera'''.slug]))
        -- Tell the owning host immediately: enabled=False publishes
        -- apCamera=Nothing (stop directive); any other edit restarts
        -- the worker pair with fresh config.
        mBus <- liftIO (readIORef busRegistry)
        forM_ mBus $ \bus -> republishAssignAlways bus camera'''
        pushResult <- liftIO (pushOnvif camera''')
        case pushResult of
          Nothing -> setSuccessMessage "Camera updated"
          Just (Left err) ->
            setErrorMessage ("Camera saved, but ONVIF push failed: " <> err)
          Just (Right summary) ->
            setSuccessMessage ("Camera updated; ONVIF: " <> summary)
        redirectTo ShowCameraAction {cameraId = camera''' |> get #id}
      else do
        formOptions <- liftIO (fetchOpts camera2)
        render EditView {camera = camera2, formOptions}
    where
      checkboxOn name = paramOrNothing @Text name == Just "on"
  action DeleteCameraAction {cameraId} = do
    camera <- fetch cameraId
    -- Stop the worker on the owning host before the row disappears.
    mBus <- liftIO (readIORef busRegistry)
    forM_ mBus $ \bus ->
      forM_ camera.assignedHost $ \host ->
        publishAssignTo bus camera host Nothing
    deleteRecord camera
    audit currentUserUuid "camera.delete" "camera" (Just (camUuid camera)) (Just (object ["slug" .= camera.slug]))
    setSuccessMessage "Camera deleted"
    redirectTo CamerasAction

  -- \| POST /ToggleCameraEnabled?cameraId=… — one-click enable/disable
  -- from the index row or Show page. Flips the flag, then publishes
  -- the assign payload immediately: enabled=False arrives as
  -- @apCamera = Nothing@ and the owning host stops the worker
  -- pair (no more RTSP requests to an offline camera).
  action ToggleCameraEnabledAction {cameraId} = do
    camera <- fetch cameraId
    now <- liftIO getCurrentTime
    camera' <-
      camera
        |> set #enabled (not camera.enabled)
        |> set #updatedAt now
        |> updateRecord
    let what = if camera'.enabled then "camera.enable" else "camera.disable"
    audit currentUserUuid what "camera" (Just (camUuid camera')) (Just (object ["slug" .= camera'.slug]))
    mBus <- liftIO (readIORef busRegistry)
    forM_ mBus $ \bus -> republishAssignAlways bus camera'
    setSuccessMessage (if camera'.enabled then "Camera enabled" else "Camera disabled — host notified")
    redirectTo ShowCameraAction {cameraId}

  -- \| Probe the main RTSP URL (and sub URL when present) with ffprobe and
  -- fill the codec + sub-stream fields. Triggered by the "Probe Streams"
  -- button on EditView. Best-effort: main-probe failure short-circuits with
  -- a flash error; sub-probe failure is logged but does not block main-probe
  -- persistence.
  action ProbeCameraAction {cameraId} = do
    camera <- fetch cameraId
    mainResult <- liftIO (probe (camera |> get #rtspUrl))
    case mainResult of
      Left err -> do
        setErrorMessage ("Probe failed (main): " <> err)
        redirectTo EditCameraAction {cameraId}
      Right mainInfo -> do
        subResult <- case camera |> get #rtspSubUrl of
          Nothing -> pure Nothing
          Just subUrl | subUrl == "" -> pure Nothing
          Just subUrl -> liftIO (fmap Just (probe subUrl))
        let camera1 =
              camera
                |> set #codec mainInfo.probeCodec
                |> applySubProbe subResult
        camera2 <- camera1 |> updateRecord
        case subResult of
          Just (Right _) -> setSuccessMessage "Probe OK (main + sub)"
          Just (Left subErr) -> setErrorMessage ("Probe OK (main); sub failed: " <> subErr)
          Nothing -> setSuccessMessage "Probe OK (main only; no sub URL)"
        redirectTo EditCameraAction {cameraId = camera2 |> get #id}
        where
          applySubProbe (Just (Right sub)) =
            set #substreamCodec sub.probeCodec
              . set #substreamWidth (Just sub.probeWidth)
              . set #substreamHeight (Just sub.probeHeight)
          applySubProbe _ = id

  -- \| POST /ProbePtzCamera?cameraId=… — discover the camera's ONVIF
  -- PTZ service (GetCapabilities), resolve the first media profile
  -- token, and enable PTZ. Reports a hardware caveat when the service
  -- answers but GetStatus returns a nil position (fixed camera whose
  -- firmware accepts PTZ ops as no-ops — e.g. the Hik-OEM turrets).
  action ProbePtzCameraAction {cameraId} = do
    camera <- fetch cameraId
    eTarget <- liftIO (targetForCamera camera)
    case eTarget of
      Left why -> do
        setErrorMessage ("PTZ probe: " <> why)
        redirectTo EditCameraAction {cameraId}
      Right target -> do
        mgr <- liftIO (HC.newManager HC.defaultManagerSettings)
        res <- liftIO (probePtz mgr target)
        case res of
          Left err -> do
            setErrorMessage ("PTZ probe failed: " <> err)
            redirectTo EditCameraAction {cameraId}
          Right (profileToken, mPos) -> do
            camera' <-
              camera
                |> set #ptzProfileToken (Just profileToken)
                |> set #ptzEnabled True
                |> updateRecord
            audit currentUserUuid "camera.probe_ptz" "camera" (Just (camUuid camera')) (Just (object ["slug" .= camera'.slug, "profile_token" .= profileToken]))
            case mPos of
              Just _ -> setSuccessMessage ("PTZ OK: service found, profile token " <> profileToken)
              Nothing ->
                setSuccessMessage
                  ( "PTZ service found (profile token "
                      <> profileToken
                      <> "), but GetStatus reports no position — this camera"
                      <> " likely has no PTZ hardware (commands accepted as no-ops)"
                  )
            redirectTo EditCameraAction {cameraId = camera' |> get #id}

  -- \| POST /AssignCamera?cameraId=… — admin override of assigned_host.
  -- Sets @manual_assign = true@ so the AssignmentCoordinator doesn't
  -- override the admin's choice. Empty host param clears the
  -- assignment and the manual pin (back to auto mode).
  action AssignCameraAction {cameraId} = do
    camera <- fetch cameraId
    let hostParam = paramOrDefault ("" :: Text) "assigned_host"
        cleared = hostParam == ""
        camera' =
          camera
            |> if cleared
              then set #assignedHost Nothing . set #manualAssign False
              else set #assignedHost (Just hostParam) . set #manualAssign True
    camera'' <- camera' |> updateRecord
    audit currentUserUuid "camera.assign" "camera" (Just (camUuid camera'')) (Just (object ["slug" .= camera''.slug, "assigned_host" .= hostParam]))
    setSuccessMessage
      $ if cleared
        then "Assignment cleared (auto mode)"
        else "Assigned to " <> hostParam
    redirectTo ShowCameraAction {cameraId = camera'' |> get #id}

  -- \| POST /TestCryptoCamera?cameraId=… — diagnostic that confirms the
  -- row's @password_enc@ + @password_nonce@ decrypt cleanly with the
  -- current @HNVR_DATA_KEY@. Catches the silent failure mode where the
  -- key was rotated between Create and a future use (e.g. a future
  -- @rtsp_template@ rendering slice, or an audit).
  --
  -- Records no state. Flash message reports OK + the decrypted length
  -- (we deliberately don't show the plaintext in the UI to keep the
  -- browser's session storage clean), or the error.
  action TestCryptoCameraAction {cameraId} = do
    camera <- fetch cameraId
    mPlain <- liftIO (decryptPassword (camera |> get #passwordEnc) (camera |> get #passwordNonce))
    case mPlain of
      Just plain ->
        setSuccessMessage
          ( "Decryption OK: password_enc decrypts cleanly with the\
            \ current HNVR_DATA_KEY (length "
              <> tshow (Text.length plain)
              <> " chars)"
          )
      Nothing ->
        setErrorMessage
          "No encrypted password stored OR decryption failed. If the\
          \ row was created with a different HNVR_DATA_KEY, the\
          \ stored ciphertext is unrecoverable; re-enter the password\
          \ in Edit to re-encrypt with the current key."
    redirectTo ShowCameraAction {cameraId}
