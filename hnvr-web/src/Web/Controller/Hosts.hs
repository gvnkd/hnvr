{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /Hosts — per-host status with assignment overview. AutoRoute maps
-- @HostsAction@ → @/Hosts@.
module Web.Controller.Hosts
  ( HostsController (..),
  )
where

import Data.Time.Clock (getCurrentTime)
import Generated.Types
import Hnvr.Core.Authz (CameraAction (..), PageKind (..))
import Hnvr.Web.Authz (aclFilterCameras, ensurePagePerm)
import Hnvr.Web.View.Hosts.Index
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)

data HostsController
  = HostsAction
  deriving stock (Eq, Show, Data)

instance AutoRoute HostsController

instance Controller HostsController where
  beforeAction = ensureIsUser
  action HostsAction = do
    ensurePagePerm PageHosts
    hosts <-
      query @Host
        |> orderByAsc #id
        |> fetch
    cameras <-
      aclFilterCameras ViewConfig (query @Camera |> filterWhere (#enabled, True))
        >>= fetch
    now <- liftIO getCurrentTime
    render IndexView {..}
