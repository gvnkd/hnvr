{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Dashboard.Index (IndexView (..)) where

import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ModelSupport (Id' (Id))
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
          <div class="subtitle">{nCams} cameras · {nHosts} hosts · click a camera for full live view</div>
        </div>
      </div>

      <div class="section-h">Live wall</div>
      {renderCameras cameras}

      <div class="section-h">Hosts</div>
      {renderHosts hosts}

      <div id="live-overlay" class="live-overlay" hidden>
        <div class="live-overlay-panel">
          <div class="live-overlay-head">
            <span class="led led-warn"></span>
            <span class="slug"></span>
            <span class="live-overlay-status">
              <span class="live-overlay-status-text">Connecting…</span>
            </span>
            <span class="spacer"></span>
            <button class="btn btn-ghost btn-sm" data-live-fullscreen="1">fullscreen</button>
            <button class="btn btn-ghost btn-sm" data-live-close="1">close ✕</button>
          </div>
          <video autoplay muted></video>
        </div>
      </div>
    |]
    where
      nCams = tshow (length cameras) :: Text
      nHosts = tshow (length hosts) :: Text

      renderHosts [] = [hsx|<div class="empty"><span class="empty-icon">⌖</span>No hosts reporting yet.</div>|]
      renderHosts hs =
        [hsx|
          <div class="card">
            <table class="table" data-sortable="1">
              <thead>
                <tr>
                  <th class="w-4" data-no-sort="1"></th>
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
          <tr data-href="/Hosts">
            <td>{healthLedFor h.lastHealthAt}</td>
            <td class="mono t-strong">{hostIdText}</td>
            <td>{roleBadgeFor h.isLeader}</td>
            <td class="mono">{fromMaybe "—" (fmap tshow h.lastHealthAt)}</td>
            <td class="mono">{fromMaybe "—" h.gpuModel}</td>
          </tr>
        |]
        where
          hostIdText = case h |> get #id of Id t -> t
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
          frameUrl = "/debug-frame/" <> cid
          showUrl = "/ShowCamera?cameraId=" <> cid
          archiveUrl = "/PlayerArchive?cameraId=" <> cid
          debugUrl = "/DebugCamera?cameraId=" <> cid
          hostLabel = fromMaybe "unassigned" cam.assignedHost
          card =
            [hsx|
              <div class="cam-card" data-slug={cam.slug} title="Click for live view">
                <div class="cam-live" data-frame-url={frameUrl}>
                  <img alt="" />
                  <img alt="" />
                  <div class="scanline"></div>
                  <div class="cam-flags">
                    <span class="badge badge-rec"><span class="led led-rec"></span>REC</span>
                    <span class="badge badge-mute">{hostLabel}</span>
                  </div>
                  <div class="cam-placeholder">
                    <span style="font-size: 22px;">◉</span>
                    <span>no signal</span>
                  </div>
                </div>
                <div class="cam-body">
                  <span class="slug">{cam.slug}</span>
                  <span class="links">
                    <a href={showUrl}>config</a>
                    <span class="faint">·</span>
                    <a href={archiveUrl}>archive</a>
                    <span class="faint">·</span>
                    <a href={debugUrl}>debug</a>
                  </span>
                </div>
              </div>
            |]
