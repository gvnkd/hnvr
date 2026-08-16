{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /AuditLog view: latest 200 admin actions, newest first. Payload
-- JSON is rendered pretty-printed in an expandable cell.
module Hnvr.Web.View.AuditLog.Index (IndexView (..)) where

import Data.Aeson (encode)
import Data.Text (Text)
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import qualified Data.UUID as UUID
import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude

data IndexView = IndexView
  { entries :: [AuditLog],
    users :: [User]
  }

instance View IndexView where
  html IndexView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Audit log</h1>
          <div class="subtitle">latest {tshow (length entries)} admin actions · newest first</div>
        </div>
      </div>

      <div class="card">
        <table class="table" data-sortable="1">
          <thead>
            <tr>
              <th>Time (UTC)</th>
              <th>User</th>
              <th>Action</th>
              <th>Target</th>
              <th data-no-sort="1">Payload</th>
            </tr>
          </thead>
          <tbody>{forEach entries renderEntry}</tbody>
        </table>
      </div>
    |]
    where
      emailFor entry = case entry.userId of
        Nothing -> "—"
        Just uid -> maybe (UUID.toText uid) (.email) (find (\u -> userUuid u == uid) users)
      userUuid u = case u |> get #id of Id uuid -> uuid

      renderEntry entry =
        [hsx|
          <tr>
            <td class="mono">{tshow entry.ts}</td>
            <td class="mono">{emailFor entry}</td>
            <td class="mono t-strong">{entry.action}</td>
            <td class="mono">{targetText entry}</td>
            <td>{payloadCell entry}</td>
          </tr>
        |]

      targetText entry =
        entry.targetType <> maybe "" (\t -> ":" <> UUID.toText t) entry.targetId

      payloadCell entry = case entry.payload of
        Nothing -> [hsx|<span class="muted">—</span>|]
        Just v ->
          [hsx|
            <details>
              <summary class="mono text-sm">json</summary>
              <pre class="mono text-sm" style="white-space:pre-wrap;margin:0.5rem 0 0">{prettyJson v}</pre>
            </details>
          |]

      prettyJson v = TL.toStrict (TLE.decodeUtf8 (encode v)) :: Text
