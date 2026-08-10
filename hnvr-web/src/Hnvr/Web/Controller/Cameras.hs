{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.Controller.Cameras
  ( CamerasController (..),
  )
where

import Generated.Types
import Hnvr.Web.Auth ()
import Hnvr.Web.Controller.Cameras.Probe (ProbeInfo (..), probe)
import Hnvr.Web.Controller.Support.Crypto (decryptPassword, encryptPassword)
import Hnvr.Web.View.Cameras.Edit
import Hnvr.Web.View.Cameras.Index
import Hnvr.Web.View.Cameras.New
import Hnvr.Web.View.Cameras.Show
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)

-- | Per-action constructor for routing. IHP's router uses this to
-- dispatch URLs to the right handler in the 'Controller' instance below.
-- Field names matter: they map to URL path components.
data CamerasController
  = IndexAction
  | ShowAction {cameraId :: !(Id Camera)}
  | NewAction
  | EditAction {cameraId :: !(Id Camera)}
  | CreateAction
  | UpdateAction {cameraId :: !(Id Camera)}
  | DeleteAction {cameraId :: !(Id Camera)}
  | ProbeAction {cameraId :: !(Id Camera)}
  | AssignAction {cameraId :: !(Id Camera)}
  deriving stock (Eq, Show, Data)

-- | Routing: relies on IHP's 'autoRoute' which uses 'Data.Data' to map
-- constructors to URL paths (e.g. @EditAction { cameraId }@ →
-- @/cameras/<uuid>/edit@).
instance AutoRoute CamerasController

instance Controller CamerasController where
  -- Gate all camera actions on a logged-in user. v1 has a single admin role
  -- (the @users.is_admin@ flag is forward-compat for Phase 6 viewer split).
  -- @ensureIsUser@ redirects unauthenticated requests to /NewSession.
  beforeAction = ensureIsUser
  action IndexAction = do
    cameras <- query @Camera |> orderByDesc #createdAt |> fetch
    render IndexView {..}
  action ShowAction {cameraId} = do
    camera <- fetch cameraId
    render ShowView {..}
  action NewAction = do
    let camera = newRecord @Camera
    render NewView {..}
  action EditAction {cameraId} = do
    camera <- fetch cameraId
    render EditView {..}
  action CreateAction = do
    let camera0 =
          newRecord @Camera
            |> fill @'["slug", "name", "rtspUrl", "rtspTemplate", "host", "port", "username", "codec", "rtspSubUrl", "rtspSubTemplate", "useSubstreamForAnalysis", "substreamCodec", "substreamWidth", "substreamHeight", "recordAudio", "analysisFps", "enabled", "retentionDays", "assignedHost", "manualAssign"]
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
        redirectTo ShowAction {cameraId = camera |> get #id}
      else render NewView {..}
  action UpdateAction {cameraId} = do
    camera <- fetch cameraId
    let camera' =
          camera
            |> fill @'["slug", "name", "rtspUrl", "rtspTemplate", "host", "port", "username", "codec", "rtspSubUrl", "rtspSubTemplate", "useSubstreamForAnalysis", "substreamCodec", "substreamWidth", "substreamHeight", "recordAudio", "analysisFps", "enabled", "retentionDays", "assignedHost", "manualAssign"]
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
        redirectTo ShowAction {cameraId = camera''' |> get #id}
      else render EditView {camera = camera''}
  action DeleteAction {cameraId} = do
    camera <- fetch cameraId
    deleteRecord camera
    setSuccessMessage "Camera deleted"
    redirectTo IndexAction

  -- \| Probe the main RTSP URL (and sub URL when present) with ffprobe and
  -- fill the codec + sub-stream fields. Triggered by the "Probe Streams"
  -- button on EditView. Best-effort: main-probe failure short-circuits with
  -- a flash error; sub-probe failure is logged but does not block main-probe
  -- persistence.
  action ProbeAction {cameraId} = do
    camera <- fetch cameraId
    mainResult <- liftIO (probe (camera |> get #rtspUrl))
    case mainResult of
      Left err -> do
        setErrorMessage ("Probe failed (main): " <> err)
        redirectTo EditAction {cameraId}
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
        redirectTo EditAction {cameraId = camera2 |> get #id}
        where
          applySubProbe (Just (Right sub)) =
            set #substreamCodec sub.probeCodec
              . set #substreamWidth (Just sub.probeWidth)
              . set #substreamHeight (Just sub.probeHeight)
          applySubProbe _ = id

  -- \| POST /cameras/:id/assign — admin override of assigned_host.
  -- Sets @manual_assign = true@ so the AssignmentCoordinator doesn't
  -- override the admin's choice. Empty host param clears the
  -- assignment and the manual pin (back to auto mode).
  action AssignAction {cameraId} = do
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
    redirectTo ShowAction {cameraId = camera'' |> get #id}
