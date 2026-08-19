{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Archive.Player (PlayerView (..)) where

import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude

data PlayerView = PlayerView
  { camera :: Camera,
    mFrom :: Maybe Text,
    mTo :: Maybe Text,
    -- | Seconds from the window start for hls.js @startPosition@
    -- (deep-link @?t=…@ auto-seek, design 05 §Events view).
    startOffset :: Maybe Int
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
          <div class="subtitle">{windowLabel}</div>
        </div>
        <div class="actions">
          <a class="btn btn-ghost" href={archiveUrl}>Browse</a>
          <a class="btn btn-ghost" href={liveUrl}>Live</a>
          <a class="btn btn-ghost" href={editUrl}>Config</a>
        </div>
      </div>

      <div class="video-frame">
        <video id="hnvr-player" controls></video>
        <button class="btn btn-ghost btn-sm zoompan-fs" data-zoompan-fs="1">fullscreen</button>
      </div>
      <div class="video-status">
        <span id="hnvr-status-led" class="led led-warn"></span>
        <span id="hnvr-status">Loading player…</span>
        <span class="faint">·</span>
        <button class="btn btn-ghost btn-sm" id="hnvr-player-fs">fullscreen</button>
      </div>
      <script src="https://cdn.jsdelivr.net/npm/hls.js@1"></script>
      {scriptTag}
    |]
    where
      playlistUrl = "/PlaylistArchive?cameraId=" <> cid <> windowParams
      windowParams = param "from" mFrom <> param "to" mTo
      param _ Nothing = ""
      param name (Just v) = "&" <> name <> "=" <> v
      windowLabel = case (mFrom, mTo) of
        (Just f, Just t) -> "Window " <> f <> " → " <> t
        _ -> "Most recent 1-hour window"
      cid = tshow (camera |> get #id)
      archiveUrl = "/Archive"
      liveUrl = "/ShowLive?cameraId=" <> cid
      editUrl = "/ShowCamera?cameraId=" <> cid
      -- IHP HSX doesn't splice {…} inside <script> tags (treats script
      -- body as pre-escaped text). Build the entire <script> element
      -- in Haskell and inject as a single body-level splice. See pitfall #63.
      scriptTag = preEscapedTextValue ("<script>" <> js <> "</script>" :: Text)

      hlsConfig = case startOffset of
        Just off -> "{ startPosition: " <> tshow off <> " }"
        Nothing -> ""

      js =
        "const video = document.getElementById('hnvr-player');"
          <> "HNVR.zoompan(video);"
          <> "const status = document.getElementById('hnvr-status');"
          <> "const led = document.getElementById('hnvr-status-led');"
          <> "function setLed(cls) { led.className = 'led ' + cls; }"
          <> "const src = '"
          <> playlistUrl
          <> "';"
          <> "if (video.canPlayType('application/vnd.apple.mpegurl')) {"
          <> "  video.src = src;"
          <> seekJs
          <> "  status.textContent = 'Native HLS (Safari)'; setLed('led-on');"
          <> "} else if (window.Hls && Hls.isSupported()) {"
          <> "  const hls = new Hls("
          <> hlsConfig
          <> ");"
          <> "  hls.loadSource(src);"
          <> "  hls.attachMedia(video);"
          <> "  hls.on(Hls.Events.MANIFEST_PARSED, () => { status.textContent = 'Ready'; setLed('led-on'); });"
          <> "  hls.on(Hls.Events.ERROR, (_, d) => { status.textContent = 'Error: ' + d.details; setLed('led-off'); });"
          <> "} else {"
          <> "  status.textContent = 'HLS not supported in this browser'; setLed('led-off');"
          <> "}"
          <> "document.getElementById('hnvr-player-fs').addEventListener('click', function () {"
          <> "  HNVR.toggleFullscreen(video.closest('.video-frame'));"
          <> "});"
      seekJs = case startOffset of
        Just off ->
          "  video.addEventListener('loadedmetadata', () => { video.currentTime = "
            <> tshow off
            <> "; });"
        Nothing -> ""
