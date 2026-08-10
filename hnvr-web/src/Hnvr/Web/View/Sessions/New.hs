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
        <h1>Login</h1>
        <form class="stacked" method="POST" action="/CreateSession">
          <div class="field-row">
            <label for="email">Email</label>
            <input id="email" name="email" type="email" value={user.email} required="1" autofocus="1" />
          </div>
          <div class="field-row">
            <label for="password">Password</label>
            <input id="password" name="password" type="password" required="1" />
          </div>
          <button class="btn" type="submit">Login</button>
        </form>
      |]
