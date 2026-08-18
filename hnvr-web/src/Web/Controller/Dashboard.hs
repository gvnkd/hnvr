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
    -- Disabled cameras are excluded entirely — a camera the operator
    -- switched off (offline, decommissioned) must not occupy grid
    -- space as a permanent "no signal" card.
    cameras <-
      query @Camera
        |> filterWhere (#enabled, True)
        |> orderByAsc #slug
        |> fetch
    hosts <-
      query @Host
        |> orderByAsc #id
        |> fetch
    -- PTZ overlay panels (Phase 5): presets for every PTZ-enabled
    -- camera; the view renders a per-camera <template> that app.js
    -- clones into the fullscreen overlay.
    ptzPresets <-
      query @PtzPreset
        |> orderBy #name
        |> fetch
    now <- liftIO getCurrentTime
    render IndexView {..}
