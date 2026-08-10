{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Archive.Player (PlayerView (..)) where

import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude

newtype PlayerView = PlayerView
  { camera :: Camera
  }

instance View PlayerView where
  html PlayerView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>
            <span class="led led-on"></span>
            Archive · <span class="font-mono">{camera.slug}</span>
          </h1>
          <div class="subtitle">HLS playback · segments served from SeaweedFS</div>
        </div>
        <div class="actions">
          <a class="btn btn-ghost" href={liveUrl}>Live</a>
          <a class="btn btn-ghost" href={editUrl}>Config</a>
        </div>
      </div>

      <div class="video-frame">
        <video id="hnvr-player" controls></video>
      </div>
      <div class="video-status">
        <span id="hnvr-status-led" class="led led-warn"></span>
        <span id="hnvr-status">Loading player…</span>
      </div>
      <script src="https://cdn.jsdelivr.net/npm/hls.js@1"></script>
      <script>{preEscapedTextValue js}</script>
    |]
    where
      playlistUrl = "/PlaylistArchive?cameraId=" <> tshow (camera |> get #id)
      cid = tshow (camera |> get #id)
      liveUrl = "/ShowLive?cameraId=" <> cid
      editUrl = "/ShowCamera?cameraId=" <> cid

      js =
        "const video = document.getElementById('hnvr-player');"
          <> "const status = document.getElementById('hnvr-status');"
          <> "const led = document.getElementById('hnvr-status-led');"
          <> "function setLed(cls) { led.className = 'led ' + cls; }"
          <> "const src = '"
          <> playlistUrl
          <> "';"
          <> "if (video.canPlayType('application/vnd.apple.mpegurl')) {"
          <> "  video.src = src;"
          <> "  status.textContent = 'Native HLS (Safari)'; setLed('led-on');"
          <> "} else if (window.Hls && Hls.isSupported()) {"
          <> "  const hls = new Hls();"
          <> "  hls.loadSource(src);"
          <> "  hls.attachMedia(video);"
          <> "  hls.on(Hls.Events.MANIFEST_PARSED, () => { status.textContent = 'Ready'; setLed('led-on'); });"
          <> "  hls.on(Hls.Events.ERROR, (_, d) => { status.textContent = 'Error: ' + d.details; setLed('led-off'); });"
          <> "} else {"
          <> "  status.textContent = 'HLS not supported in this browser'; setLed('led-off');"
          <> "}"
