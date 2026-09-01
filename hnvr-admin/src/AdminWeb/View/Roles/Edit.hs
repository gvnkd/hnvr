{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /EditRole — grant matrix for an existing (non-system) role.
module AdminWeb.View.Roles.Edit (EditView (..)) where

import AdminWeb.BasePath (urlFor)
import AdminWeb.Grants (RoleGrants)
import AdminWeb.View.Layout (renderAdminLayout)
import AdminWeb.View.Roles.Form (roleFormFields)
import qualified Data.UUID as UUID
import Generated.Types
import IHP.ModelSupport (Id' (..))
import IHP.ViewPrelude

data EditView = EditView
  { role :: Role,
    grants :: RoleGrants,
    cameras :: [Camera]
  }

instance View EditView where
  html EditView {..} =
    renderAdminLayout
      [hsx|
      <div class="page-header">
        <div><h1>Edit role · <span class="font-mono t-accent">{role.name}</span></h1><div class="subtitle">grants replace wholesale on save</div></div>
        <div class="actions"><a class="btn btn-ghost" href={urlFor "/Roles"}>← Back</a></div>
      </div>
      <div class="card">
        <div class="card-body">
          <form class="form" method="POST" action={updateUrl}>
            {roleFormFields role grants cameras}
            <div class="mt-6">
              <button class="btn btn-primary" type="submit">Save role</button>
            </div>
          </form>
        </div>
      </div>
    |]
    where
      updateUrl = urlFor ("/UpdateRole?roleId=" <> idText)
      idText = case role |> get #id of Id u -> UUID.toText u
