{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Live view: @\<video\>@ + inline WHEP client.
--
-- The WHEP client is vanilla JS (no npm, no fetch polyfill — Chrome 100+
-- is the target). Flow:
--   1. Build RTCPeerConnection, add transceivers (video+audio recvonly).
--   2. createOffer → setLocalDescription → wait for ICE gathering.
--   3. POST SDP offer to /whep/<slug> → expect 201 + SDP answer.
--   4. setRemoteDescription → ontrack fires → attach to <video>.
module Hnvr.Web.View.Live.Show (ShowView (..)) where

import Data.Time.Clock (UTCTime)
import Generated.Types
import Hnvr.Core.CameraStatus (CameraStatus (..))
import Hnvr.Web.CameraStatus (cameraStatusFor)
import Hnvr.Web.View.Layout (renderLayout)
import Hnvr.Web.View.PtzPanel (ptzPanel)
import IHP.ViewPrelude

data ShowView = ShowView
  { camera :: Camera,
    hosts :: [Host],
    presets :: [PtzPreset],
    now :: UTCTime
  }

instance View ShowView where
  html ShowView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>
            <span id="hnvr-live-hdr-led" class={hdrLedClass}></span>
            Live · <span class="font-mono">{camera.slug}</span>
            {offlineBadge}
          </h1>
          <div class="subtitle">WebRTC via WHEP · {fromMaybe "—" camera.assignedHost}</div>
        </div>
        <div class="actions">
          <a class="btn btn-ghost" href={archiveUrl}>Archive</a>
          <a class="btn btn-ghost" href="/Cameras">Cameras</a>
        </div>
      </div>

      <div class="video-frame">
        <video id="hnvr-live" autoplay muted controls></video>
      </div>
      <div class="video-status">
        <span id="hnvr-live-led" class="led led-warn"></span>
        <span id="hnvr-live-status">Connecting…</span>
        <span class="faint">·</span>
        <button class="btn btn-ghost btn-sm" id="hnvr-live-fs">fullscreen</button>
      </div>
      <div class="card mt-4">
        <div class="card-header">Events</div>
        <div class="card-body" id="hnvr-live-feed">
          <div class="text-sm muted">loading…</div>
        </div>
      </div>
      {ptzPanel'}
      {ptzScriptTag}
      {scriptTag}
    |]
    where
      archiveUrl = "/PlayerArchive?cameraId=" <> tshow (camera |> get #id)
      camStatus = cameraStatusFor hosts now camera
      -- Initial header LED from the server-known worker state; the WHEP
      -- client takes over once the page's WebRTC session negotiates.
      hdrLedClass = case camStatus of
        CSRecording -> "led led-rec" :: Text
        _ -> "led led-off"
      offlineBadge = case camStatus of
        CSRecording -> mempty
        CSStarting -> [hsx|<span class="badge badge-warn">STARTING</span>|]
        CSReconnecting -> [hsx|<span class="badge badge-warn">RECONNECTING</span>|]
        CSFailed -> [hsx|<span class="badge badge-danger">FAILED</span>|]
        CSHostDown -> [hsx|<span class="badge badge-danger">HOST DOWN</span>|]
        CSNotRunning -> [hsx|<span class="badge badge-mute">STOPPED</span>|]
        CSUnassigned -> [hsx|<span class="badge badge-mute">UNASSIGNED</span>|]
        CSDisabled -> [hsx|<span class="badge badge-mute">DISABLED</span>|]
      -- IHP HSX deliberately does NOT splice {…} inside <script> tags
      -- (parser treats script/style bodies as pre-escaped text so that
      -- CSS like `h1 { color:red }` doesn't get re-parsed). Build the
      -- entire <script>…</script> element in Haskell and inject it as
      -- a single body-level splice. See pitfall #63.
      scriptTag = preEscapedTextValue ("<script>" <> whepJs camera <> feedJs camera <> "</script>" :: Text)
      ptzScriptTag =
        if camera.ptzEnabled
          then preEscapedTextValue ("<script src=\"/static/ptz.js\"></script><script>HNVR.ptz('" <> tshow (camera |> get #id) <> "');</script>" :: Text)
          else mempty

      -- PTZ control panel (Phase 5): shared markup from
      -- 'Hnvr.Web.View.PtzPanel' (also used by the dashboard overlay);
      -- hidden unless ptz_enabled, behaviour in /static/ptz.js.
      ptzPanel' =
        if not camera.ptzEnabled
          then mempty
          else [hsx|<div class="mt-4">{ptzPanel camera presets}</div>|]

-- | Live event feed poller: refreshes the panel from the fragment
-- endpoint every 5 s (design 05 §"Live event feed"; a fetch poller
-- instead of IHP autoRefresh — our layout doesn't load ihp.js).
feedJs :: Camera -> Text
feedJs cam =
  "const feedEl = document.getElementById('hnvr-live-feed');"
    <> "const feedUrl = '/EventsFeedLive?liveCameraId="
    <> tshow (cam |> get #id)
    <> "';"
    <> "async function refreshFeed() {"
    <> "  try {"
    <> "    const r = await fetch(feedUrl);"
    <> "    if (r.ok) feedEl.innerHTML = await r.text();"
    <> "  } catch (e) { /* keep last good fragment */ }"
    <> "}"
    <> "refreshFeed(); setInterval(refreshFeed, 5000);"

-- | Inline WHEP bootstrap: delegates to the shared client in
-- /static/app.js (HNVR.whep) and maps its state callbacks onto the
-- status pill + both LEDs (header LED doubles as the REC indicator).
-- app.js is loaded in <head> (no defer) so the HNVR global exists by
-- the time body-level page scripts run.
whepJs :: Camera -> Text
whepJs cam =
  "const video = document.getElementById('hnvr-live');"
    <> "HNVR.zoompan(video);"
    <> "const status = document.getElementById('hnvr-live-status');"
    <> "const led = document.getElementById('hnvr-live-led');"
    <> "const hdrLed = document.getElementById('hnvr-live-hdr-led');"
    <> "function setLeds(pillCls, hdrCls) { led.className = 'led ' + pillCls; hdrLed.className = 'led ' + hdrCls; }"
    <> "HNVR.whep('"
    <> cam.slug
    <> "', video, function (state) {"
    <> "  if (state === 'live') { status.textContent = 'Live'; setLeds('led-on', 'led-rec'); }"
    <> "  else if (state === 'reconnecting') { status.textContent = 'Reconnecting…'; setLeds('led-warn', 'led-warn'); }"
    <> "  else if (state === 'connecting') { status.textContent = 'Connecting…'; setLeds('led-warn', 'led-warn'); }"
    <> "  else { status.textContent = 'Error: ' + state.replace(/^error:\\s*/, ''); setLeds('led-off', 'led-off'); }"
    <> "});"
    <> "document.getElementById('hnvr-live-fs').addEventListener('click', function () {"
    <> "  var f = video.closest('.video-frame');"
    <> "  if (f && f.requestFullscreen) f.requestFullscreen();"
    <> "});"
