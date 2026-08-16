{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | / Dashboard — camera grid + per-host panel. Mounted at @/@ via
-- @startPage DashboardAction@ in the front controller (the action lives
-- at @/Dashboard@ via AutoRoute; @startPage@ adds the @/@ alias).
module Web.Controller.Dashboard
  ( DashboardController (..),
  )
where

import Data.Time.Clock (getCurrentTime)
import Generated.Types
import Hnvr.Web.View.Dashboard.Index
import IHP.ControllerPrelude

data DashboardController
  = DashboardAction
  deriving stock (Eq, Show, Data)

instance AutoRoute DashboardController

instance Controller DashboardController where
  action DashboardAction = do
    cameras <-
      query @Camera
        |> orderByAsc #slug
        |> fetch
    hosts <-
      query @Host
        |> orderByAsc #id
        |> fetch
    now <- liftIO getCurrentTime
    render IndexView {..}
