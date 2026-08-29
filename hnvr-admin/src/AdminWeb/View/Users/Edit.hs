{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /EditUser — password reset + role assignment. The last-superadmin
-- guard is enforced by the controller; the view shows which roles are
-- system ones.
module AdminWeb.View.Users.Edit (EditView (..)) where

import AdminWeb.View.Layout (renderAdminLayout)
import AdminWeb.View.Users.RoleBoxes (roleCheckboxes)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Generated.Types
import IHP.ModelSupport (Id' (..))
import IHP.ViewPrelude

data EditView = EditView
  { user :: User,
    roles :: [Role],
    assigned :: [UUID]
  }

instance View EditView where
  html EditView {..} =
    renderAdminLayout
      [hsx|
      <div class="page-header">
        <div><h1>Edit user · <span class="font-mono t-accent">{user.email}</span></h1><div class="subtitle">blank password keeps the current one</div></div>
        <div class="actions"><a class="btn btn-ghost" href="/Users">← Back</a></div>
      </div>
      <div class="card">
        <div class="card-body">
          <form class="form" method="POST" action={updateUrl}>
            <div class="field">
              <label for="password">New password</label>
              <input class="input" id="password" name="password" type="password" />
            </div>
            <div class="section-h">Roles</div>
            {roleCheckboxes roles assigned}
            <div class="mt-6">
              <button class="btn btn-primary" type="submit">Save user</button>
            </div>
          </form>
        </div>
      </div>
    |]
    where
      updateUrl = "/UpdateUser?userId=" <> idText
      idText = case user |> get #id of Id u -> UUID.toText u
