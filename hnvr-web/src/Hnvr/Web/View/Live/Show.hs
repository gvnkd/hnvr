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
      <div class="header">
        <h1>Live · {camera.slug}</h1>
      </div>
      <video id="hnvr-live" autoplay muted
             style="width:100%; max-width:1100px; background:#000;"></video>
      <p id="hnvr-live-status">Connecting…</p>
      <script>{preEscapedTextValue (whepJs camera)}</script>
    |]

-- | Inline WHEP client. ~40 LOC vanilla JS. Talks to our /whep/<slug>
-- proxy which forwards to MediaMTX.
whepJs :: Camera -> Text
whepJs cam =
  "const video = document.getElementById('hnvr-live');"
    <> "const status = document.getElementById('hnvr-live-status');"
    <> "const pc = new RTCPeerConnection();"
    <> "pc.addTransceiver('video', { direction: 'recvonly' });"
    <> "pc.addTransceiver('audio', { direction: 'recvonly' });"
    <> "pc.ontrack = e => { video.srcObject = e.streams[0]; status.textContent = 'Live'; };"
    <> "pc.onconnectionstatechange = () => {"
    <> "  if (pc.connectionState === 'failed' || pc.connectionState === 'disconnected') {"
    <> "    status.textContent = 'Reconnecting…';"
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
    <> "}).catch(e => { status.textContent = 'Error: ' + e.message; });"
