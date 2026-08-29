{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Admin login. Same User model as the end-user app, but the session
-- cookie is @hnvr_admin@ (Config) so the two services never share a
-- session. IHP's built-in login view renders the form.
module Web.Controller.Sessions
  ( SessionsController (..),
  )
where

import AdminWeb.View.Layout (renderAdminLayout)
import Control.Monad (void)
import Data.Time.Clock (getCurrentTime)
import Generated.Types
import Hnvr.Web.Auth ()
import IHP.AuthSupport.Controller.Sessions (SessionsControllerConfig (..))
import qualified IHP.AuthSupport.Controller.Sessions as Sessions
import IHP.AuthSupport.View.Sessions.New (NewView (..))
import IHP.ControllerPrelude
import IHP.ModelSupport (Id' (..), sqlExec)
import IHP.ViewPrelude (View (..))

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

-- | Same contract as the leader's: stamp last_login_at after password
-- verification only (IHP guarantee).
instance SessionsControllerConfig User where
  beforeLogin user = do
    now <- getCurrentTime
    let Id userUuid = user |> get #id
    void (sqlExec "UPDATE users SET last_login_at = ? WHERE id = ?" (now, userUuid))

-- | Login page on the admin layout (the leader's instance lives in
-- Hnvr.Web.View.Sessions.New, which this package never imports — one
-- instance per binary).
instance View (NewView User) where
  html NewView {user} =
    renderAdminLayout
      [hsx|
        <div class="login-shell">
          <div class="login-card">
            <div class="login-body">
              <h1><span class="led led-rec"></span> HNVR <span class="badge badge-warn">admin</span></h1>
              <div class="subtitle">sign in to continue</div>
              <form class="form" method="POST" action="/CreateSession">
                <div class="field">
                  <label for="email">Email</label>
                  <input class="input" id="email" name="email" type="email" value={user.email} required="1" autofocus="1" />
                </div>
                <div class="field">
                  <label for="password">Password</label>
                  <input class="input" id="password" name="password" type="password" required="1" />
                </div>
                <button class="btn btn-primary w-full justify-center mt-2" type="submit">Login →</button>
              </form>
            </div>
          </div>
        </div>
      |]
