{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /ShowLive?cameraId=… view. Renders the @\<video\>@ element + inline
-- WHEP client. The WHEP POST/PATCH/DELETE traffic is handled by
-- @Hnvr.Web.WhepProxy@ at the WAI layer, so this controller only owns
-- the HTML rendering.
module Web.Controller.Live
  ( LiveController (..),
  )
where

import Data.Time.Clock (getCurrentTime)
import Generated.Types
import Hnvr.Web.View.Live.Show
import IHP.ControllerPrelude
import IHP.ModelSupport (Id' (Id))

newtype LiveController
  = ShowLiveAction {cameraId :: Id Camera}
  deriving stock (Eq, Show, Data)

instance AutoRoute LiveController

instance Controller LiveController where
  action ShowLiveAction {cameraId} = do
    camera <- fetch cameraId
    hosts <- query @Host |> fetch
    -- PTZ panel preset dropdown (Phase 5); empty when PTZ is off.
    presets <-
      if camera.ptzEnabled
        then query @PtzPreset |> filterWhere (#cameraId, camUuid camera) |> orderBy #name |> fetch
        else pure []
    now <- liftIO getCurrentTime
    render ShowView {..}
    where
      camUuid cam = case cam |> get #id of Id u -> u
