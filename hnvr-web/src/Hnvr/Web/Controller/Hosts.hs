{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /hosts — per-host status with assignment overview.
module Hnvr.Web.Controller.Hosts
  ( HostsController (..),
  )
where

import Generated.Types
import Hnvr.Web.View.Hosts.Index
import IHP.ControllerPrelude

data HostsController
  = IndexAction
  deriving stock (Eq, Show, Data)

instance AutoRoute HostsController

instance Controller HostsController where
  action IndexAction = do
    hosts <-
      query @Host
        |> orderByAsc #id
        |> fetch
    cameras <-
      query @Camera
        |> filterWhere (#enabled, True)
        |> fetch
    render IndexView {..}
