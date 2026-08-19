{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /DebugCamera?cameraId=… — Phase 3 debug view: live analysis frame
-- with bbox overlay + current track legend. Dev-only.
-- /StreamDebugCamera?cameraId=… — the multipart PNG stream feeding the
-- view's @\<img\>@ ('Hnvr.Web.DebugStream.debugStreamResponse' via a
-- raw WAI response; lives here so 'ensureIsUser' covers it — the old
-- /debug-stream WAI route was unauthenticated).
module Web.Controller.Debug
  ( DebugController (..),
  )
where

import Generated.Types
import Hnvr.Node.CaptureSupervisor (analysisTVar, latestAnalysis)
import Hnvr.Web.Auth ()
import Hnvr.Web.CommandTypes (cameraIdOf)
import Hnvr.Web.DebugStream (debugStreamResponse)
import Hnvr.Web.SupervisorRegistry (supervisorRegistry)
import Hnvr.Web.View.Debug.Show
import IHP.Controller.Response (respondAndExit)
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)

data DebugController
  = DebugCameraAction {cameraId :: Id Camera}
  | StreamDebugCameraAction {cameraId :: Id Camera}
  deriving stock (Eq, Show, Data)

instance AutoRoute DebugController

instance Controller DebugController where
  beforeAction = ensureIsUser

  action DebugCameraAction {cameraId} = do
    camera <- fetch cameraId
    tracks <- liftIO $ do
      mSup <- readIORef supervisorRegistry
      case mSup of
        Nothing -> pure []
        Just sup -> maybe [] snd <$> latestAnalysis sup (cameraIdOf camera)
    render ShowView {..}
  action StreamDebugCameraAction {cameraId} = do
    camera <- fetch cameraId
    mTVar <- liftIO $ do
      mSup <- readIORef supervisorRegistry
      case mSup of
        Nothing -> pure Nothing
        Just sup -> analysisTVar sup (cameraIdOf camera)
    case mTVar of
      Nothing -> renderPlain "no analysis running for this camera on this host"
      Just tvar -> respondAndExit (debugStreamResponse tvar)
