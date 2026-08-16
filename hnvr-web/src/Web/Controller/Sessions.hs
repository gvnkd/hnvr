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
module Web.Controller.Sessions
  ( SessionsController (..),
  )
where

import Control.Monad (void)
import Data.Time.Clock (getCurrentTime)
import Generated.Types
import Hnvr.Web.View.Sessions.New
import IHP.AuthSupport.Controller.Sessions (SessionsControllerConfig (..))
import qualified IHP.AuthSupport.Controller.Sessions as Sessions
import IHP.ControllerPrelude
import IHP.ModelSupport (Id' (..), sqlExec)

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
-- beforeLogin runs only AFTER password verification (IHP guarantee), so
-- last_login_at stamps successful logins only.
instance SessionsControllerConfig User where
  beforeLogin user = do
    now <- getCurrentTime
    let Id userUuid = user |> get #id
    void (sqlExec "UPDATE users SET last_login_at = ? WHERE id = ?" (now, userUuid))
