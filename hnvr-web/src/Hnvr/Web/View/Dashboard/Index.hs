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
      <div class="page-header">
        <div>
          <h1>Dashboard</h1>
          <div class="subtitle">{nCams} cameras · {nHosts} hosts</div>
        </div>
      </div>

      <div class="section-h">Hosts</div>
      {renderHosts hosts}

      <div class="section-h">Cameras</div>
      {renderCameras cameras}
    |]
    where
      nCams = tshow (length cameras) :: Text
      nHosts = tshow (length hosts) :: Text

      renderHosts [] = [hsx|<div class="empty"><span class="empty-icon">⌖</span>No hosts reporting yet.</div>|]
      renderHosts hs =
        [hsx|
          <div class="card">
            <table class="table">
              <thead>
                <tr>
                  <th class="w-4"></th>
                  <th>Host</th>
                  <th>Role</th>
                  <th>Last health</th>
                  <th>GPU</th>
                </tr>
              </thead>
              <tbody>{forEach hs renderHost}</tbody>
            </table>
          </div>
        |]
      renderHost h =
        [hsx|
          <tr>
            <td>{healthLedFor h.lastHealthAt}</td>
            <td class="mono text-zinc-100">{h.id}</td>
            <td>{roleBadgeFor h.isLeader}</td>
            <td class="mono">{fromMaybe "—" (fmap tshow h.lastHealthAt)}</td>
            <td class="mono">{fromMaybe "—" h.gpuModel}</td>
          </tr>
        |]
      healthLedFor mh
        | Just _ <- mh = [hsx|<span class="led led-on" title="reporting"></span>|]
        | otherwise = [hsx|<span class="led led-off" title="never seen"></span>|]
      roleBadgeFor True = [hsx|<span class="badge badge-info">LEADER</span>|]
      roleBadgeFor False = [hsx|<span class="badge badge-mute">WORKER</span>|]

      renderCameras [] = [hsx|<div class="empty"><span class="empty-icon">⌖</span>No cameras yet. Add some via the Cameras page.</div>|]
      renderCameras cs =
        [hsx|
          <div class="cam-grid">
            {forEach cs renderCamera}
          </div>
        |]
      renderCamera cam = card
        where
          cid = tshow (cam |> get #id)
          liveUrl = "/ShowLive?cameraId=" <> cid
          showUrl = "/ShowCamera?cameraId=" <> cid
          archiveUrl = "/PlayerArchive?cameraId=" <> cid
          debugUrl = "/DebugCamera?cameraId=" <> cid
          hostLabel = fromMaybe "unassigned" cam.assignedHost
          card =
            [hsx|
              <div class="cam-card group">
                <a class="cam-thumb" href={liveUrl}>
                  <span class="rec-flag">
                    <span class="led led-rec"></span>REC
                  </span>
                  <span class="host-flag">{hostLabel}</span>
                  <span class="play-icon">▶</span>
                </a>
                <div class="cam-body">
                  <span class="slug">{cam.slug}</span>
                  <span class="links">
                    <a href={showUrl}>config</a>
                    <span class="text-zinc-700">·</span>
                    <a href={archiveUrl}>archive</a>
                    <span class="text-zinc-700">·</span>
                    <a href={debugUrl}>debug</a>
                  </span>
                </div>
              </div>
            |]
