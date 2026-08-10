{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Login form view, mounted on IHP's @NewView User@ from
-- @IHP.AuthSupport.View.Sessions.New@.
module Hnvr.Web.View.Sessions.New () where

import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.AuthSupport.View.Sessions.New (NewView (..))
import IHP.ViewPrelude

instance View (NewView User) where
  html NewView {user} =
    renderLayout
      [hsx|
        <div class="login-shell">
          <div class="login-card">
            <div class="login-body">
              <h1>
                <span class="led led-rec"></span>
                HNVR
              </h1>
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
