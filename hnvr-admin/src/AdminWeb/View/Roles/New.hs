{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /NewRole — blank grant form.
module AdminWeb.View.Roles.New (NewView (..)) where

import AdminWeb.Grants (RoleGrants)
import AdminWeb.View.Layout (renderAdminLayout)
import AdminWeb.View.Roles.Form (roleFormFields)
import Generated.Types
import IHP.ViewPrelude

data NewView = NewView
  { role :: Role,
    grants :: RoleGrants,
    cameras :: [Camera]
  }

instance View NewView where
  html NewView {..} =
    renderAdminLayout
      [hsx|
      <div class="page-header">
        <div><h1>New role</h1><div class="subtitle">default-deny: nothing is granted until checked</div></div>
        <div class="actions"><a class="btn btn-ghost" href="/Roles">← Back</a></div>
      </div>
      <div class="card">
        <div class="card-body">
          <form class="form" method="POST" action="/CreateRole">
            {roleFormFields role grants cameras}
            <div class="mt-6">
              <button class="btn btn-primary" type="submit">Create role</button>
            </div>
          </form>
        </div>
      </div>
    |]
