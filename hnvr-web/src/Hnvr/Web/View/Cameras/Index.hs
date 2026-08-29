{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Cameras.Index (IndexView (..)) where

import Generated.Types
import Hnvr.Core.Authz (CameraAction (..), cameraAllowed, cameraAllowedAnywhere)
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Web.Authz (currentRoleSet)
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ModelSupport (Id' (Id))
import IHP.ViewPrelude

data IndexView = IndexView
  { cameras :: [Camera],
    drifts :: [CameraDrift]
  }

instance View IndexView where
  html IndexView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Cameras</h1>
          <div class="subtitle">{nCams} configured · click a row for details</div>
        </div>
        <div class="actions">
          {newBtn}
        </div>
      </div>
      {renderCameras cameras}
    |]
    where
      nCams = tshow (length cameras) :: Text
      -- Roles & ACL (design_docs/13): creation needs any edit_config
      -- grant; per-row toggle/edit need it on that camera.
      rs = currentRoleSet
      canCreate = cameraAllowedAnywhere rs EditConfig
      newBtn =
        if canCreate
          then [hsx|<a class="btn btn-primary" href="/NewCamera">+ New Camera</a>|]
          else mempty

      renderCameras [] =
        [hsx|
          <div class="empty">
            <span class="empty-icon">⌖</span>
            No cameras yet.
            <div class="mt-3">{newBtn}</div>
          </div>
        |]
      renderCameras cs =
        [hsx|
          <div class="card">
            <div class="card-header">
              <span>sources</span>
              <input class="table-filter" type="text" placeholder="filter…" data-table-filter="#cameras-table" />
            </div>
            <table class="table" id="cameras-table" data-sortable="1">
              <thead>
                <tr>
                  <th>Slug</th>
                  <th>Name</th>
                  <th>Main</th>
                  <th>Sub</th>
                  <th>Host</th>
                  <th>Sync</th>
                  <th class="text-right" data-no-sort="1">Actions</th>
                </tr>
              </thead>
              <tbody>{forEach cs renderCamera}</tbody>
            </table>
          </div>
        |]

      renderCamera camera =
        [hsx|
          <tr data-href={showUrl} class={rowClass}>
            <td class="mono t-strong">{camera.slug} {enabledBadge}</td>
            <td>{camera.name}</td>
            <td>{codecBadge camera.codec}</td>
            <td>{subCodecBadge camera}</td>
            <td class="mono">{fromMaybe "—" camera.assignedHost}</td>
            <td>{syncBadge camera}</td>
            <td class="text-right whitespace-nowrap">
              {toggleBtn camera}
              <a href={showUrl} class="btn btn-ghost btn-sm">Show</a>
              {editBtn camera}
            </td>
          </tr>
        |]
        where
          cid = tshow (camera |> get #id)
          showUrl = "/ShowCamera?cameraId=" <> cid
          editUrl = "/EditCamera?cameraId=" <> cid
          toggleUrl = "/ToggleCameraEnabled?cameraId=" <> cid
          canEdit = cameraAllowed rs EditConfig (camIdOf camera)
          camIdOf c = case c |> get #id of Id u -> CameraId u
          toggleBtn camera' =
            if not canEdit
              then mempty
              else
                [hsx|
                  <form method="POST" action={toggleUrl} style="display:contents">
                    <button type="submit" class={toggleClass}>{toggleLabel}</button>
                  </form>
                |]
          editBtn camera' =
            if canEdit
              then [hsx|<a href={editUrl} class="btn btn-ghost btn-sm">Edit</a>|]
              else mempty
          enabledBadge =
            if camera.enabled
              then [hsx|<span class="badge badge-ok">ON</span>|]
              else [hsx|<span class="badge badge-mute">OFF</span>|]
          toggleLabel = if camera.enabled then "Disable" else "Enable"
          toggleClass = if camera.enabled then "btn btn-ghost btn-sm" else "btn btn-sm"
          rowClass = if camera.enabled then "" else "row-disabled"

      codecBadge Unknown = [hsx|<span class="badge badge-mute">UNKNOWN</span>|]
      codecBadge H264 = [hsx|<span class="badge badge-info">H264</span>|]
      codecBadge Hevc = [hsx|<span class="badge badge-warn">HEVC</span>|]

      -- \| Sub-stream codec badge; "—" when the camera has no sub URL.
      subCodecBadge camera = case camera.rtspSubUrl of
        Nothing -> [hsx|<span class="badge badge-mute">—</span>|]
        Just "" -> [hsx|<span class="badge badge-mute">—</span>|]
        Just _ -> codecBadge camera.substreamCodec

      syncBadge camera
        | isNothing camera.onvifPort = [hsx|<span class="badge badge-mute">—</span>|]
        | n > 0 = [hsx|<span class="badge badge-warn">DRIFT {n}</span>|]
        | otherwise = [hsx|<span class="badge badge-ok">SYNCED</span>|]
        where
          n = length (filter (\d -> d.cameraId == camUuidOf camera) drifts) :: Int

      camUuidOf camera = case camera |> get #id of Id u -> u
