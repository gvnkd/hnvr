{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /Users — user list with assigned roles.
module AdminWeb.View.Users.Index (IndexView (..)) where

import AdminWeb.BasePath (urlFor)
import AdminWeb.View.Layout (renderAdminLayout)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.UUID as UUID
import Generated.Types
import Hnvr.Web.View.Time (tzTime)
import IHP.ModelSupport (Id' (..))
import IHP.ViewPrelude

newtype IndexView = IndexView
  { users :: [(User, [Role])]
  }

instance View IndexView where
  html IndexView {..} =
    renderAdminLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Users</h1>
          <div class="subtitle">{tshow (length users)} users · roles only (is_admin retired in 0.22)</div>
        </div>
        <div class="actions">
          <a class="btn btn-primary" href={urlFor "/NewUser"}>+ New User</a>
        </div>
      </div>
      {renderUsers users}
    |]
    where
      renderUsers [] = [hsx|<div class="empty"><span class="empty-icon">◍</span>No users yet.</div>|]
      renderUsers us =
        [hsx|
          <div class="card">
            <table class="table" data-sortable="1">
              <thead>
                <tr><th>Email</th><th>Roles</th><th>Last login</th><th class="text-right" data-no-sort="1">Actions</th></tr>
              </thead>
              <tbody>{forEach us renderUser}</tbody>
            </table>
          </div>
        |]
      renderUser (user, roles) =
        [hsx|
          <tr>
            <td class="mono t-strong">{user.email}</td>
            <td class="text-sm">{roleNames roles}</td>
            <td class="mono">{maybe "—" tzTime user.lastLoginAt}</td>
            <td class="text-right whitespace-nowrap">
              <a href={editUrl} class="btn btn-ghost btn-sm">Edit</a>
              <form method="POST" action={purgeUrl} style="display:contents" data-confirm={"Delete user " <> user.email <> "?"}>
                <button type="submit" class="btn btn-ghost btn-sm">Delete</button>
              </form>
            </td>
          </tr>
        |]
        where
          editUrl = urlFor ("/EditUser?userId=" <> idText)
          purgeUrl = urlFor ("/PurgeUser?userId=" <> idText)
          idText = case user |> get #id of Id u -> UUID.toText u

roleNames :: [Role] -> Text
roleNames rs = T.intercalate ", " (map (.name) rs)
