{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /DebugCamera?cameraId=… — Phase 3 debug view: live analysis frame
-- with bbox overlay (streamed by @Hnvr.Web.DebugStream@ at the WAI
-- layer) + current track legend. Dev-only.
module Web.Controller.Debug
  ( DebugController (..),
  )
where

import Generated.Types
import Hnvr.Node.CaptureSupervisor (latestAnalysis)
import Hnvr.Web.Auth ()
import Hnvr.Web.CommandTypes (cameraIdOf)
import Hnvr.Web.SupervisorRegistry (supervisorRegistry)
import Hnvr.Web.View.Debug.Show
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)

newtype DebugController
  = DebugCameraAction {cameraId :: Id Camera}
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
