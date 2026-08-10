{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /live/<slug> view. Renders the @\<video\>@ element + inline WHEP
-- client. The WHEP POST/PATCH/DELETE traffic is handled by
-- @Hnvr.Web.WhepProxy@ at the WAI layer, so this controller only owns
-- the HTML rendering.
module Hnvr.Web.Controller.Live
  ( LiveController (..),
  )
where

import Generated.Types
import Hnvr.Web.View.Live.Show
import IHP.ControllerPrelude

newtype LiveController
  = ShowAction {cameraId :: Id Camera}
  deriving stock (Eq, Show, Data)

instance AutoRoute LiveController

instance Controller LiveController where
  action ShowAction {cameraId} = do
    camera <- fetch cameraId
    render ShowView {..}
