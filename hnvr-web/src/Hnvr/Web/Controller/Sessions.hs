{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | IHP AuthSupport sessions controller.
--
-- Wires the three standard session actions to IHP's @createSessionAction@ /
-- @newSessionAction@ / @deleteSessionAction@ over our 'User' model.
-- AutoRoute maps:
--
--   * @NewSessionAction@    → @/NewSession@
--   * @CreateSessionAction@ → @/CreateSession@
--   * @DeleteSessionAction@ → @/DeleteSession@
--
-- (top-level URLs, no controller prefix — IHP default).
module Hnvr.Web.Controller.Sessions
  ( SessionsController (..),
  )
where

import Generated.Types
import Hnvr.Web.View.Sessions.New
import IHP.AuthSupport.Controller.Sessions (SessionsControllerConfig)
import qualified IHP.AuthSupport.Controller.Sessions as Sessions
import IHP.ControllerPrelude

data SessionsController
  = NewSessionAction
  | CreateSessionAction
  | DeleteSessionAction
  deriving stock (Eq, Show, Data)

instance AutoRoute SessionsController

instance Controller SessionsController where
  action NewSessionAction = Sessions.newSessionAction @User
  action CreateSessionAction = Sessions.createSessionAction @User
  action DeleteSessionAction = Sessions.deleteSessionAction @User

-- Default config: afterLoginRedirectPath = "/", maxFailedLoginAttempts = 10.
-- Override methods here if HNVR needs custom login throttle / redirect.
instance SessionsControllerConfig User
