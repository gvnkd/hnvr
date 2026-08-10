{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | / Dashboard — camera grid + per-host panel.
module Hnvr.Web.Controller.Dashboard
  ( DashboardController (..),
  )
where

import Generated.Types
import Hnvr.Web.View.Dashboard.Index
import IHP.ControllerPrelude

data DashboardController
  = IndexAction
  deriving stock (Eq, Show, Data)

instance AutoRoute DashboardController

instance Controller DashboardController where
  action IndexAction = do
    cameras <-
      query @Camera
        |> orderByAsc #slug
        |> fetch
    hosts <-
      query @Host
        |> orderByAsc #id
        |> fetch
    render IndexView {..}
