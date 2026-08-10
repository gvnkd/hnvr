{-# LANGUAGE TypeFamilies #-}

-- | Root front controller for the HNVR leader.
module Hnvr.Web.FrontController
  ( RootApplication (..),
  )
where

import IHP.ControllerSupport (InitControllerContext (..))
import IHP.FrameworkConfig (RootApplication (..))
import IHP.Job.Types (Worker (..))
import IHP.RouterSupport (FrontController (..), parseRoute, startPage)
import Web.Controller.Archive (ArchiveController (..))
import Web.Controller.Cameras (CamerasController (..))
import Web.Controller.Dashboard (DashboardController (..))
import Web.Controller.Hosts (HostsController (..))
import Web.Controller.Live (LiveController (..))
import Web.Controller.Sessions (SessionsController (..))

instance FrontController RootApplication where
  controllers =
    [ -- / → DashboardAction (also reachable at /Dashboard via AutoRoute)
      startPage DashboardAction,
      parseRoute @SessionsController,
      parseRoute @DashboardController,
      parseRoute @CamerasController,
      parseRoute @HostsController,
      parseRoute @ArchiveController,
      parseRoute @LiveController
    ]

instance Worker RootApplication where
  workers _ = []

instance InitControllerContext RootApplication where
  initContext = pure ()
