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
--   * @AssignCameraAction@   → @/AssignCamera?cameraId=…@ (POST)
module Web.Controller.Cameras
  ( CamerasController (..),
  )
where

import Data.Text (Text)
import qualified Data.Text as Text
import Generated.Types
import Hnvr.Web.Auth ()
import Hnvr.Web.View.Cameras.Edit
import Hnvr.Web.View.Cameras.Index
import Hnvr.Web.View.Cameras.New
import Hnvr.Web.View.Cameras.Show
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)
import Web.Controller.Cameras.Probe (ProbeInfo (..), probe)
import Web.Controller.Support.Crypto (decryptPassword, encryptPassword)

data CamerasController
  = CamerasAction
  | ShowCameraAction {cameraId :: !(Id Camera)}
  | NewCameraAction
  | EditCameraAction {cameraId :: !(Id Camera)}
  | CreateCameraAction
  | UpdateCameraAction {cameraId :: !(Id Camera)}
  | DeleteCameraAction {cameraId :: !(Id Camera)}
  | ProbeCameraAction {cameraId :: !(Id Camera)}
  | AssignCameraAction {cameraId :: !(Id Camera)}
  | TestCryptoCameraAction {cameraId :: !(Id Camera)}
  deriving stock (Eq, Show, Data)

instance AutoRoute CamerasController

instance Controller CamerasController where
  beforeAction = ensureIsUser
  action CamerasAction = do
    cameras <- query @Camera |> orderByDesc #createdAt |> fetch
    render IndexView {..}
  action ShowCameraAction {cameraId} = do
    camera <- fetch cameraId
    render ShowView {..}
  action NewCameraAction = do
    let camera = newRecord @Camera
    render NewView {..}
  action EditCameraAction {cameraId} = do
    camera <- fetch cameraId
    render EditView {..}
  action CreateCameraAction = do
    let camera0 =
          newRecord @Camera
            |> fill @'["slug", "name", "rtspUrl", "rtspTemplate", "rtspTransport", "host", "port", "username", "codec", "rtspSubUrl", "rtspSubTemplate", "useSubstreamForAnalysis", "substreamCodec", "substreamWidth", "substreamHeight", "recordAudio", "analysisFps", "enabled", "retentionDays", "assignedHost", "manualAssign"]
        plaintext = paramOrDefault ("" :: Text) "password"
    (enc, nonce) <- liftIO (encryptPassword plaintext)
    let camera =
          camera0
            |> set #passwordEnc (Just enc)
            |> set #passwordNonce (Just nonce)
    if camera |> isValid
      then do
        camera <- camera |> createRecord
        setSuccessMessage "Camera created"
        redirectTo ShowCameraAction {cameraId = camera |> get #id}
      else render NewView {..}
  action UpdateCameraAction {cameraId} = do
    camera <- fetch cameraId
    let camera' =
          camera
            |> fill @'["slug", "name", "rtspUrl", "rtspTemplate", "rtspTransport", "host", "port", "username", "codec", "rtspSubUrl", "rtspSubTemplate", "useSubstreamForAnalysis", "substreamCodec", "substreamWidth", "substreamHeight", "recordAudio", "analysisFps", "enabled", "retentionDays", "assignedHost", "manualAssign"]
        plaintext = paramOrNothing "password" :: Maybe Text
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
    if camera'' |> isValid
      then do
        camera''' <- camera'' |> updateRecord
        setSuccessMessage "Camera updated"
        redirectTo ShowCameraAction {cameraId = camera''' |> get #id}
      else render EditView {camera = camera''}
  action DeleteCameraAction {cameraId} = do
    camera <- fetch cameraId
    deleteRecord camera
    setSuccessMessage "Camera deleted"
    redirectTo CamerasAction

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
          ( "No encrypted password stored OR decryption failed. If the\
            \ row was created with a different HNVR_DATA_KEY, the\
            \ stored ciphertext is unrecoverable; re-enter the password\
            \ in Edit to re-encrypt with the current key."
          )
    redirectTo ShowCameraAction {cameraId}
