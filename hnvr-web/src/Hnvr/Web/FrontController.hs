{-# LANGUAGE TypeFamilies #-}

-- | Root front controller for the HNVR leader.
module Hnvr.Web.FrontController
  ( RootApplication (..),
  )
where

import Hnvr.Web.Controller.Archive (ArchiveController (..))
import Hnvr.Web.Controller.Cameras (CamerasController (..))
import Hnvr.Web.Controller.Dashboard (DashboardController (..))
import Hnvr.Web.Controller.Hosts (HostsController (..))
import Hnvr.Web.Controller.Live (LiveController (..))
import IHP.ControllerSupport (InitControllerContext (..))
import IHP.FrameworkConfig (RootApplication (..))
import IHP.Job.Types (Worker (..))
import IHP.RouterSupport (FrontController (..), parseRoute)

instance FrontController RootApplication where
  controllers =
    [ parseRoute @DashboardController,
      parseRoute @CamerasController,
      parseRoute @HostsController,
      parseRoute @ArchiveController,
      parseRoute @LiveController
    ]

instance Worker RootApplication where
  workers _ = []

instance InitControllerContext RootApplication where
  initContext = pure ()
