{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /NewUser — email + password + role checkboxes.
module AdminWeb.View.Users.New (NewView (..)) where

import AdminWeb.View.Layout (renderAdminLayout)
import AdminWeb.View.Users.RoleBoxes (roleCheckboxes)
import Data.UUID (UUID)
import Generated.Types
import IHP.ViewPrelude

data NewView = NewView
  { user :: User,
    roles :: [Role],
    assigned :: [UUID]
  }

instance View NewView where
  html NewView {..} =
    renderAdminLayout
      [hsx|
      <div class="page-header">
        <div><h1>New user</h1><div class="subtitle">local account; assign roles below</div></div>
        <div class="actions"><a class="btn btn-ghost" href="/Users">← Back</a></div>
      </div>
      <div class="card">
        <div class="card-body">
          <form class="form" method="POST" action="/CreateUser">
            <div class="field">
              <label for="email">Email</label>
              <input class="input" id="email" name="email" type="email" autocomplete="off" required />
            </div>
            <div class="field">
              <label for="password">Password</label>
              <input class="input" id="password" name="password" type="password" autocomplete="new-password" required />
            </div>
            <div class="section-h">Roles</div>
            {roleCheckboxes roles assigned}
            <div class="mt-6">
              <button class="btn btn-primary" type="submit">Create user</button>
            </div>
          </form>
        </div>
      </div>
    |]
