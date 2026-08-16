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
import Hnvr.Web.View.Hosts.Index
import IHP.ControllerPrelude

data HostsController
  = HostsAction
  deriving stock (Eq, Show, Data)

instance AutoRoute HostsController

instance Controller HostsController where
  action HostsAction = do
    hosts <-
      query @Host
        |> orderByAsc #id
        |> fetch
    cameras <-
      query @Camera
        |> filterWhere (#enabled, True)
        |> fetch
    now <- liftIO getCurrentTime
    render IndexView {..}
