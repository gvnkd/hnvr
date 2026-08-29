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
import Web.Controller.AuditLog (AuditLogController (..))
import Web.Controller.Dashboard (DashboardController (..))
import Web.Controller.Debug (DebugController (..))
import Web.Controller.EventClips (EventClipsController (..))
import Web.Controller.Events (EventsController (..))
import Web.Controller.Hosts (HostsController (..))
import Web.Controller.Live (LiveController (..))
import Web.Controller.Profile (ProfileController (..))
import Web.Controller.Ptz (PtzController (..))
import Web.Controller.Sessions (SessionsController (..))
import Web.Controller.Stats (StatsController (..))
import Web.Controller.Timeline (TimelineController (..))

-- | The end-user app is read-mostly (design_docs/13, M4): camera/rule/
-- preset management lives in hnvr-admin — those routes are GONE here,
-- not just hidden.
instance FrontController RootApplication where
  controllers =
    [ -- / → DashboardAction (also reachable at /Dashboard via AutoRoute)
      startPage DashboardAction,
      parseRoute @SessionsController,
      parseRoute @ProfileController,
      parseRoute @DashboardController,
      parseRoute @HostsController,
      parseRoute @ArchiveController,
      parseRoute @LiveController,
      parseRoute @DebugController,
      parseRoute @EventsController,
      parseRoute @EventClipsController,
      parseRoute @PtzController,
      parseRoute @StatsController,
      parseRoute @AuditLogController,
      parseRoute @TimelineController
    ]

instance Worker RootApplication where
  workers _ = []

instance InitControllerContext RootApplication where
  initContext = pure ()
