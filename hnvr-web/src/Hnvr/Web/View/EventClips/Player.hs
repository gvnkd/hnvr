{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Event-clip player page (separated event video store). Same hls.js
-- wiring as the archive player, but the playlist comes from
-- 'PlaylistEventClipAction' (prefix-listed, presigned) instead of the
-- segments table.
module Hnvr.Web.View.EventClips.Player (ClipPlayerView (..)) where

import qualified Data.Text as T
import Data.Time.Format (defaultTimeLocale, formatTime)
import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude

data ClipPlayerView = ClipPlayerView
  { clip :: EventClip,
    camera :: Camera
  }

instance View ClipPlayerView where
  html ClipPlayerView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>
            <span class="led led-on"></span>
            Event clip · <span class="font-mono">{camera.slug}</span>
          </h1>
          <div class="subtitle">{clipLabel}</div>
        </div>
        <div class="actions">
          <a class="btn btn-ghost" href="/Events">Events</a>
          <a class="btn btn-ghost" href={liveUrl}>Live</a>
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
      {scriptTag}
    |]
    where
      playlistUrl = "/PlaylistEventClip?playlistClipId=" <> tshow (clip |> get #id)
      clipLabel =
        T.pack (formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S" clip.startedAt)
          <> " UTC · "
          <> tshow clip.durationSec
          <> "s · retention "
          <> tshow clip.retentionHours
          <> "h"
      liveUrl = "/ShowLive?cameraId=" <> tshow (camera |> get #id)
      -- IHP HSX doesn't splice {…} inside <script> tags (pitfall #63):
      -- build the whole element in Haskell, splice at body level.
      scriptTag = preEscapedTextValue ("<script>" <> js <> "</script>" :: Text)
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
