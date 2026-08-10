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
      <div class="header">
        <h1>Archive · {camera.slug}</h1>
      </div>
      <video id="hnvr-player" controls style="width:100%; max-width:1100px; background:#000;"></video>
      <p id="hnvr-status">Loading player…</p>
      <script src="https://cdn.jsdelivr.net/npm/hls.js@1"></script>
      <script>{preEscapedTextValue js}</script>
    |]
    where
      playlistUrl = "/cameras/" <> tshow (camera |> get #id) <> "/playlist"
      js =
        "const video = document.getElementById('hnvr-player');"
          <> "const status = document.getElementById('hnvr-status');"
          <> "const src = '"
          <> playlistUrl
          <> "';"
          <> "if (video.canPlayType('application/vnd.apple.mpegurl')) {"
          <> "  video.src = src;"
          <> "  status.textContent = 'Native HLS (Safari)';"
          <> "} else if (window.Hls && Hls.isSupported()) {"
          <> "  const hls = new Hls();"
          <> "  hls.loadSource(src);"
          <> "  hls.attachMedia(video);"
          <> "  hls.on(Hls.Events.MANIFEST_PARSED, () => { status.textContent = 'Ready'; });"
          <> "  hls.on(Hls.Events.ERROR, (_, d) => { status.textContent = 'Error: ' + d.details; });"
          <> "} else {"
          <> "  status.textContent = 'HLS not supported in this browser';"
          <> "}"
