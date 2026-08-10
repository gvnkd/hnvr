{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Dashboard.Index (IndexView (..)) where

import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude

data IndexView = IndexView
  { cameras :: [Camera],
    hosts :: [Host]
  }

instance View IndexView where
  html IndexView {..} =
    renderLayout
      [hsx|
      <div class="header">
        <h1>Dashboard</h1>
      </div>

      <h2>Hosts</h2>
      {renderHosts hosts}

      <h2>Cameras</h2>
      {renderCameras cameras}
    |]
    where
      renderHosts [] = [hsx|<p>No hosts reporting yet.</p>|]
      renderHosts hs =
        [hsx|
          <table>
            <thead>
              <tr><th>Host</th><th>Leader</th><th>Last health</th><th>GPU</th></tr>
            </thead>
            <tbody>{forEach hs renderHost}</tbody>
          </table>
        |]
      renderHost h =
        [hsx|
          <tr>
            <td>{h.id}</td>
            <td>{tshow h.isLeader}</td>
            <td>{fromMaybe "—" (fmap tshow h.lastHealthAt)}</td>
            <td>{fromMaybe "—" h.gpuModel}</td>
          </tr>
        |]

      renderCameras [] = [hsx|<p>No cameras yet. Add some via the Cameras page.</p>|]
      renderCameras cs =
        [hsx|
          <div class="grid">
            {forEach cs renderCamera}
          </div>
        |]
      renderCamera cam = [hsx|{card}|]
        where
          cid = tshow cam.id
          liveUrl = "/live/" <> cam.slug
          showUrl = "/cameras/" <> cid
          archiveUrl = "/cameras/" <> cid <> "/archive"
          card =
            [hsx|
              <div class="card">
                <a class="thumb" href={liveUrl}>▶</a>
                <div class="card-body">
                  <strong>{cam.slug}</strong>
                  <div class="meta">{fromMaybe "—" cam.assignedHost}</div>
                  <a href={showUrl}>config</a>
                  ·
                  <a href={archiveUrl}>archive</a>
                </div>
              </div>
            |]
