{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /Roles — role list with grant summary.
module AdminWeb.View.Roles.Index (IndexView (..)) where

import AdminWeb.BasePath (urlFor)
import AdminWeb.Grants (RoleGrants (..))
import AdminWeb.View.Layout (renderAdminLayout)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.UUID as UUID
import Generated.Types
import Hnvr.Core.Authz
import IHP.ModelSupport (Id' (..))
import IHP.ViewPrelude

newtype IndexView = IndexView
  { roles :: [(Role, RoleGrants, Int)]
  }

instance View IndexView where
  html IndexView {..} =
    renderAdminLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Roles</h1>
          <div class="subtitle">{tshow (length roles)} roles · superadmin is system-managed; guest is ordinary — delete it for a full login wall</div>
        </div>
        <div class="actions">
          <a class="btn btn-primary" href={urlFor "/NewRole"}>+ New Role</a>
        </div>
      </div>
      {renderRoles roles}
    |]
    where
      renderRoles [] = [hsx|<div class="empty"><span class="empty-icon">⚿</span>No roles yet.</div>|]
      renderRoles rs =
        [hsx|
          <div class="card">
            <table class="table" data-sortable="1">
              <thead>
                <tr><th>Name</th><th>Pages</th><th>Wildcard actions</th><th>Overrides</th><th>Holders</th><th class="text-right" data-no-sort="1">Actions</th></tr>
              </thead>
              <tbody>{forEach rs renderRole}</tbody>
            </table>
          </div>
        |]
      renderRole (role, grants, holders) =
        [hsx|
          <tr>
            <td class="mono t-strong">{role.name} {systemBadge}</td>
            <td class="text-sm">{pageList grants}</td>
            <td class="text-sm">{wildList grants}</td>
            <td class="mono">{tshow (length (grants.rgOverrides))}</td>
            <td class="mono">{tshow holders}</td>
            <td class="text-right whitespace-nowrap">{actionCell}</td>
          </tr>
        |]
        where
          systemBadge =
            if role.isSystem
              then [hsx|<span class="badge badge-info">SYSTEM</span>|]
              else mempty
          actionCell =
            if role.isSystem
              then [hsx|<span class="muted text-sm">immutable</span>|]
              else
                [hsx|
                  <a href={editUrl} class="btn btn-ghost btn-sm">Edit</a>
                  <form method="POST" action={purgeUrl} style="display:contents" data-confirm={"Delete role " <> role.name <> "?"}>
                    <button type="submit" class="btn btn-ghost btn-sm">Delete</button>
                  </form>
                |]
          editUrl = urlFor ("/EditRole?roleId=" <> idText)
          purgeUrl = urlFor ("/PurgeRole?roleId=" <> idText)
          idText = case role |> get #id of Id u -> UUID.toText u

pageList :: RoleGrants -> Text
pageList g = T.intercalate ", " (map pageKindToText g.rgPages)

wildList :: RoleGrants -> Text
wildList g = T.intercalate ", " (map cameraActionToText g.rgWildcard)
