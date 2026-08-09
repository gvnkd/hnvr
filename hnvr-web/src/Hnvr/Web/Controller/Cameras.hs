{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}

module Hnvr.Web.Controller.Cameras
  ( CamerasController (..)
  ) where

import Generated.Types
import Hnvr.Web.Controller.Cameras.Probe (ProbeInfo (..), probe)
import Hnvr.Web.Controller.Support.Crypto (decryptPassword, encryptPassword)
import Hnvr.Web.View.Cameras.Edit
import Hnvr.Web.View.Cameras.Index
import Hnvr.Web.View.Cameras.New
import Hnvr.Web.View.Cameras.Show
import IHP.ControllerPrelude

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
  deriving stock (Eq, Show, Data)

-- | Routing: relies on IHP's 'autoRoute' which uses 'Data.Data' to map
-- constructors to URL paths (e.g. @EditAction { cameraId }@ →
-- @/cameras/<uuid>/edit@).
instance AutoRoute CamerasController

instance Controller CamerasController where
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
    let camera = camera0
          |> set #passwordEnc (Just enc)
          |> set #passwordNonce (Just nonce)
    if camera |> isValid
      then do
        camera <- camera |> createRecord
        setSuccessMessage "Camera created"
        redirectTo ShowAction {cameraId = camera.id}
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
        pure (camera'
                |> set #passwordEnc (Just enc)
                |> set #passwordNonce (Just nonce))
    if camera'' |> isValid
      then do
        camera''' <- camera'' |> updateRecord
        setSuccessMessage "Camera updated"
        redirectTo ShowAction {cameraId = camera'''.id}
      else render EditView {camera = camera''}

  action DeleteAction {cameraId} = do
    camera <- fetch cameraId
    deleteRecord camera
    setSuccessMessage "Camera deleted"
    redirectTo IndexAction

  -- | Probe the main RTSP URL with ffprobe and fill codec/width/height.
  -- Triggered by the "Probe" button on EditView. Best-effort: failures
  -- set a flash error and redirect back to Edit.
  action ProbeAction {cameraId} = do
    camera <- fetch cameraId
    result <- liftIO (probe (camera |> get #rtspUrl))
    case result of
      Left err -> do
        setErrorMessage ("Probe failed: " <> err)
        redirectTo EditAction {cameraId}
      Right info -> do
        camera <-
          camera
            |> set #codec info.probeCodec
            |> set #substreamWidth (camera |> get #substreamWidth)
            |> set #substreamHeight (camera |> get #substreamHeight)
            |> updateRecord
        setSuccessMessage "Probe OK"
        redirectTo EditAction {cameraId = camera.id}
