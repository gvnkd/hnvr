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

newtype LiveController
  = ShowLiveAction {cameraId :: Id Camera}
  deriving stock (Eq, Show, Data)

instance AutoRoute LiveController

instance Controller LiveController where
  action ShowLiveAction {cameraId} = do
    camera <- fetch cameraId
    hosts <- query @Host |> fetch
    now <- liftIO getCurrentTime
    render ShowView {..}
