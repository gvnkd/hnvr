{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | @/@ overview: user/role counts + recent admin_audit entries.
module AdminWeb.View.Overview.Index (IndexView (..)) where

import AdminWeb.View.Layout (renderAdminLayout)
import Data.Aeson (encode)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.UUID as UUID
import Generated.Types
import Hnvr.Web.View.Time (tzTime)
import IHP.ModelSupport (Id' (..))
import IHP.ViewPrelude

data IndexView = IndexView
  { nUsers :: Int,
    nRoles :: Int,
    nHolders :: Int,
    entries :: [AdminAudit]
  }

instance View IndexView where
  html IndexView {..} =
    renderAdminLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Admin</h1>
          <div class="subtitle">{tshow nUsers} users · {tshow nRoles} roles · {tshow nHolders} assignments</div>
        </div>
        <div class="actions">
          <a class="btn" href="/Roles">Roles</a>
          <a class="btn" href="/Users">Users</a>
        </div>
      </div>

      <div class="section-h">Recent admin activity</div>
      {renderEntries entries}
    |]
    where
      renderEntries [] = [hsx|<div class="empty"><span class="empty-icon">≣</span>No admin actions recorded yet.</div>|]
      renderEntries es =
        [hsx|
          <div class="card">
            <table class="table" data-sortable="1">
              <thead>
                <tr><th>When</th><th>Actor</th><th>Action</th><th>Object</th><th>Payload</th></tr>
              </thead>
              <tbody>{forEach es renderEntry}</tbody>
            </table>
          </div>
        |]
      renderEntry e =
        [hsx|
          <tr>
            <td class="mono">{tzTime e.createdAt}</td>
            <td class="mono">{actorText}</td>
            <td class="mono t-strong">{e.action}</td>
            <td class="mono">{objectText}</td>
            <td class="mono text-sm">{payloadText}</td>
          </tr>
        |]
        where
          actorText = maybe "—" (T.take 8 . UUID.toText) e.actorId :: Text
          objectText = e.objectKind <> maybe "" (" · " <>) e.objectId :: Text
          payloadText = maybe "—" (cs . encode) e.payload :: Text
