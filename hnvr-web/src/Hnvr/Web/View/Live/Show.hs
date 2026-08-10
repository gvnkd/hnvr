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

import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude

newtype ShowView = ShowView
  { camera :: Camera
  }

instance View ShowView where
  html ShowView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>
            <span class="led led-rec"></span>
            Live · <span class="font-mono">{camera.slug}</span>
          </h1>
          <div class="subtitle">WebRTC via WHEP · {fromMaybe "—" camera.assignedHost}</div>
        </div>
        <div class="actions">
          <a class="btn btn-ghost" href={archiveUrl}>Archive</a>
          <a class="btn btn-ghost" href="/Cameras">Cameras</a>
        </div>
      </div>

      <div class="video-frame">
        <video id="hnvr-live" autoplay muted></video>
      </div>
      <div class="video-status">
        <span id="hnvr-live-led" class="led led-warn"></span>
        <span id="hnvr-live-status">Connecting…</span>
      </div>
      <script>{preEscapedTextValue (whepJs camera)}</script>
    |]
    where
      archiveUrl = "/PlayerArchive?cameraId=" <> tshow (camera |> get #id)

-- | Inline WHEP client. ~40 LOC vanilla JS. Talks to our /whep/<slug>
-- proxy which forwards to MediaMTX. Updates the status pill + LED
-- element based on connection state.
whepJs :: Camera -> Text
whepJs cam =
  "const video = document.getElementById('hnvr-live');"
    <> "const status = document.getElementById('hnvr-live-status');"
    <> "const led = document.getElementById('hnvr-live-led');"
    <> "function setLed(cls) { led.className = 'led ' + cls; }"
    <> "const pc = new RTCPeerConnection();"
    <> "pc.addTransceiver('video', { direction: 'recvonly' });"
    <> "pc.addTransceiver('audio', { direction: 'recvonly' });"
    <> "pc.ontrack = e => { video.srcObject = e.streams[0]; status.textContent = 'Live'; setLed('led-on'); };"
    <> "pc.onconnectionstatechange = () => {"
    <> "  if (pc.connectionState === 'failed' || pc.connectionState === 'disconnected') {"
    <> "    status.textContent = 'Reconnecting…'; setLed('led-warn');"
    <> "  } else if (pc.connectionState === 'connected') {"
    <> "    status.textContent = 'Live'; setLed('led-on');"
    <> "  }"
    <> "};"
    <> "const whepUrl = '/whep/"
    <> cam.slug
    <> "';"
    <> "pc.createOffer().then(o => pc.setLocalDescription(o)).then(() => {"
    <> "  return new Promise(resolve => {"
    <> "    if (pc.iceGatheringState === 'complete') resolve();"
    <> "    else pc.onicegatheringstatechange = () => { if (pc.iceGatheringState === 'complete') resolve(); };"
    <> "  });"
    <> "}).then(() => {"
    <> "  return fetch(whepUrl, {"
    <> "    method: 'POST',"
    <> "    headers: { 'Content-Type': 'application/sdp' },"
    <> "    body: pc.localDescription.sdp"
    <> "  });"
    <> "}).then(r => {"
    <> "  if (!r.ok) throw new Error('WHEP POST failed: ' + r.status);"
    <> "  return r.text();"
    <> "}).then(answer => {"
    <> "  pc.setRemoteDescription({ type: 'answer', sdp: answer });"
    <> "}).catch(e => { status.textContent = 'Error: ' + e.message; setLed('led-off'); });"
