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
      archiveUrl = "/Timeline"
      liveUrl = "/ShowLive?cameraId=" <> cid
      editUrl = "/ShowCamera?cameraId=" <> cid
      -- IHP HSX doesn't splice {…} inside <script> tags (treats script
      -- body as pre-escaped text). Build the entire <script> element
      -- in Haskell and inject as a single body-level splice. See pitfall #63.
      scriptTag = preEscapedTextValue ("<script>" <> js <> "</script>" :: Text)

      -- Buffer caps bound hls.js's forward loading; the bad-append
      -- guard stops the "black screen while the whole playlist
      -- downloads" failure mode on old recordings whose skewed A/V
      -- timestamps make MSE reject/overlap every segment (v0.15.0.0).
      hlsConfig =
        "{ maxBufferLength: 30, maxMaxBufferLength: 60, maxBufferSize: 60000000, backBufferLength: 30, maxBufferHole: 0.6, maxSeekHole: 4, nudgeMaxRetry: 12"
          <> (case startOffset of Just off -> ", startPosition: " <> tshow off; Nothing -> "")
          <> " }"

      js =
        "const video = document.getElementById('hnvr-player');"
          <> "HNVR.zoompan(video);"
          <> "const status = document.getElementById('hnvr-status');"
          <> "const led = document.getElementById('hnvr-status-led');"
          <> "function setLed(cls) { led.className = 'led ' + cls; }"
          <> "const src = '"
          <> playlistUrl
          <> "';"
          -- HNVR.hlsArchive repairs EXTINF durations + strips legacy
          -- skewed audio up-front; native HLS is the Safari fallback.
          <> "if (window.Hls && Hls.isSupported()) {"
          <> "  let badAppends = 0;"
          <> "  let started = false;"
          <> "  video.addEventListener('playing', () => { started = true; });"
          <> "  const kickStart = () => {"
          <> "    if (started || !video.buffered.length) return;"
          <> "    const first = video.buffered.start(0);"
          <> "    if (video.currentTime + 0.25 < first) { try { video.currentTime = first + 0.05; } catch (e) {} }"
          <> "    if (video.paused) video.play().catch(() => {});"
          <> "  };"
          <> "  HNVR.hlsArchive(Hls, video, src, "
          <> hlsConfig
          <> ").then((hls) => {"
          <> "  hls.on(Hls.Events.BUFFER_APPENDED, kickStart);"
          <> "  hls.on(Hls.Events.MANIFEST_PARSED, () => { status.textContent = 'Ready'; setLed('led-on'); });"
          <> "  hls.on(Hls.Events.ERROR, (_, d) => {"
          <> "    if (d.details === 'bufferAppendNoProgress' || d.details === 'bufferAppendError' || d.details === 'bufferFullError') {"
          <> "      if (video.currentTime > 0) return;"
          <> "      if (++badAppends > 40) { hls.destroy(); status.textContent = 'Recording unreadable (bad timestamps)'; setLed('led-off'); }"
          <> "      return;"
          <> "    }"
          <> "    status.textContent = 'Error: ' + d.details; setLed('led-off');"
          <> "  });"
          <> "  });"
          <> "} else if (video.canPlayType('application/vnd.apple.mpegurl')) {"
          <> "  video.src = src;"
          <> seekJs
          <> "  status.textContent = 'Native HLS (Safari)'; setLed('led-on');"
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
