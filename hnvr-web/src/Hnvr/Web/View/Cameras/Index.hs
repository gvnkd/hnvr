{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Cameras.Index (IndexView (..)) where

import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude

newtype IndexView = IndexView
  { cameras :: [Camera]
  }

instance View IndexView where
  html IndexView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Cameras</h1>
          <div class="subtitle">{nCams} configured</div>
        </div>
        <div class="actions">
          <a class="btn btn-primary" href="/NewCamera">+ New Camera</a>
        </div>
      </div>
      {renderCameras cameras}
    |]
    where
      nCams = tshow (length cameras) :: Text

      renderCameras [] =
        [hsx|
          <div class="empty">
            <span class="empty-icon">⌖</span>
            No cameras yet.
            <div class="mt-3"><a class="btn btn-primary" href="/NewCamera">+ New Camera</a></div>
          </div>
        |]
      renderCameras cs =
        [hsx|
          <div class="card">
            <table class="table">
              <thead>
                <tr>
                  <th>Slug</th>
                  <th>Name</th>
                  <th>Codec</th>
                  <th>Host</th>
                  <th class="text-right">Actions</th>
                </tr>
              </thead>
              <tbody>{forEach cs renderCamera}</tbody>
            </table>
          </div>
        |]

      renderCamera camera =
        [hsx|
          <tr>
            <td class="mono text-zinc-100">{camera.slug}</td>
            <td>{camera.name}</td>
            <td>{codecBadge camera.codec}</td>
            <td class="mono">{fromMaybe "—" camera.assignedHost}</td>
            <td class="text-right whitespace-nowrap">
              <a href={showUrl} class="btn btn-ghost btn-sm">Show</a>
              <a href={editUrl} class="btn btn-ghost btn-sm">Edit</a>
            </td>
          </tr>
        |]
        where
          cid = tshow (camera |> get #id)
          showUrl = "/ShowCamera?cameraId=" <> cid
          editUrl = "/EditCamera?cameraId=" <> cid

      codecBadge Unknown = [hsx|<span class="badge badge-mute">UNKNOWN</span>|]
      codecBadge H264 = [hsx|<span class="badge badge-info">H264</span>|]
      codecBadge Hevc = [hsx|<span class="badge badge-warn">HEVC</span>|]
