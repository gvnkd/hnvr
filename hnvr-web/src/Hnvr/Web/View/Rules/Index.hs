{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /Rules view: rule list with camera, kind, classes, and edit/purge
-- actions (Phase 4).
module Hnvr.Web.View.Rules.Index
  ( IndexView (..),
  )
where

import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Generated.Types
import Hnvr.Cv.Decode (cocoClassName)
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ModelSupport (Id' (Id))
import IHP.ViewPrelude

data IndexView = IndexView
  { rules :: [Rule],
    cameras :: [Camera]
  }

instance View IndexView where
  html IndexView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Rules</h1>
          <div class="subtitle">line crossing + zone intrusion</div>
        </div>
      </div>

      <div class="card">
        <table class="table">
          <thead>
            <tr>
              <th>Name</th>
              <th>Camera</th>
              <th>Kind</th>
              <th>Classes</th>
              <th>Cooldown</th>
              <th>Enabled</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {forEach rules renderRule}
          </tbody>
        </table>
      </div>
    |]
    where
      renderRule rule =
        [hsx|
        <tr>
          <td>{rule.name}</td>
          <td class="font-mono">{cameraSlug rule.cameraId}</td>
          <td>{kindBadge rule.kind}</td>
          <td>{classList rule.classes}</td>
          <td class="mono">{tshow rule.cooldownMs} ms</td>
          <td>{enabledBadge rule.enabled}</td>
          <td>
            <a class="btn btn-ghost" href={editUrl}>edit</a>
            <form method="POST" action={purgeUrl} style="display:inline">
              <button class="btn btn-ghost" type="submit">delete</button>
            </form>
          </td>
        </tr>
      |]
        where
          rid = tshow (rule |> get #id)
          editUrl = "/EditRule?ruleId=" <> rid
          purgeUrl = "/PurgeRule?ruleId=" <> rid

      cameraSlug :: UUID -> Text
      cameraSlug uuid =
        maybe "?" (.slug) (find (\c -> camUuid c == uuid) cameras)

      camUuid c = case c |> get #id of Id u -> u

      classList cs = T.intercalate ", " (map cocoClassName cs)

      kindBadge LineCross = [hsx|<span class="badge badge-warn">line cross</span>|]
      kindBadge RuleKindZoneEnter = [hsx|<span class="badge badge-info">zone enter</span>|]
      kindBadge RuleKindZoneExit = [hsx|<span class="badge badge-info">zone exit</span>|]
      kindBadge RuleKindZoneInside = [hsx|<span class="badge badge-mute">zone inside</span>|]

      enabledBadge True = [hsx|<span class="badge badge-info">on</span>|]
      enabledBadge False = [hsx|<span class="badge badge-mute">off</span>|]
