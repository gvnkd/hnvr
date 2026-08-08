{-# LANGUAGE TypeFamilies #-}

-- | Root front controller for the HNVR leader.
--
-- IHP requires this instance even if empty — it's the entry point of the
-- routing tree. Real controllers (cameras CRUD, archive, events) land in
-- Phase 1; for Phase 0 the only HTTP-level behaviour we need is the
-- healthcheck served by 'Hnvr.Web.Config.healthzMiddleware'.
module Hnvr.Web.FrontController () where

import IHP.FrameworkConfig (RootApplication (..))
import IHP.Job.Types (Worker (..))
import IHP.RouterSupport (FrontController (..))

instance FrontController RootApplication where
  controllers = []

instance Worker RootApplication where
  workers _ = []
