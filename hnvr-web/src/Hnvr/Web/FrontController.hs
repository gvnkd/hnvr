{-# LANGUAGE TypeFamilies #-}

-- | Root front controller for the HNVR leader.
module Hnvr.Web.FrontController
  ( RootApplication (..)
  ) where

import Hnvr.Web.Controller.Archive (ArchiveController (..))
import Hnvr.Web.Controller.Cameras (CamerasController (..))
import IHP.ControllerSupport (InitControllerContext (..))
import IHP.FrameworkConfig (RootApplication (..))
import IHP.Job.Types (Worker (..))
import IHP.RouterSupport (FrontController (..), parseRoute)

instance FrontController RootApplication where
  controllers =
    [ parseRoute @CamerasController
    , parseRoute @ArchiveController
    ]

instance Worker RootApplication where
  workers _ = []

instance InitControllerContext RootApplication where
  initContext = pure ()
