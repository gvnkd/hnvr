{-# LANGUAGE TypeFamilies #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Root front controller for hnvr-admin. IHP is single-app per binary:
-- 'RootApplication' and its classes come from IHP, so this instance is
-- an orphan BY DESIGN — the leader's 'Hnvr.Web.FrontController' is
-- never imported into this package.
module AdminWeb.FrontController
  ( RootApplication (..),
  )
where

import IHP.ControllerSupport (InitControllerContext (..))
import IHP.FrameworkConfig (RootApplication (..))
import IHP.Job.Types (Worker (..))
import IHP.RouterSupport (FrontController (..), parseRoute, startPage)
import Web.Controller.Overview (OverviewController (..))
import Web.Controller.Roles (RolesController (..))
import Web.Controller.Sessions (SessionsController (..))
import Web.Controller.Users (UsersController (..))

instance FrontController RootApplication where
  controllers =
    [ startPage OverviewAction,
      parseRoute @SessionsController,
      parseRoute @OverviewController,
      parseRoute @RolesController,
      parseRoute @UsersController
    ]

instance Worker RootApplication where
  workers _ = []

instance InitControllerContext RootApplication where
  initContext = pure ()
