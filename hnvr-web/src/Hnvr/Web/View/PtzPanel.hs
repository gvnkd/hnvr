{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Shared PTZ control panel markup (Phase 5), rendered as a sliding
-- right-side drawer. Mounted directly on /ShowLive and inside
-- per-camera @\<template\>@s on the dashboard (app.js clones the
-- template into the fullscreen overlay on open). Sliding behaviour is
-- the delegated @[data-ptz-toggle]@ click handler in app.js;
-- command behaviour lives in @/static/ptz.js@
-- (@HNVR.ptz(cameraId, root)@).
--
-- Callers must only render this for logged-in users (the dashboard and
-- live views are anonymous-readable; the PTZ POST endpoints are
-- ensureIsUser-gated, so an anonymous panel would be dead UI).
--
-- No top-level signature: the Html type carries implicit params
-- (pitfall #36), the enclosing view's scope provides them.
module Hnvr.Web.View.PtzPanel
  ( ptzPanel,
  )
where

import Generated.Types
import IHP.ViewPrelude

ptzPanel camera presets =
  [hsx|
  <aside class="ptz-drawer" id="ptz-panel" data-camera-id={cid}>
    <div class="ptz-drawer-head">
      <span>PTZ</span>
      <span id="ptz-status" class="badge badge-mute">…</span>
      <span class="spacer"></span>
      <button class="btn btn-ghost btn-sm" data-ptz-toggle="1">close ✕</button>
    </div>
    <div class="ptz-drawer-body">
      <div class="ptz-body">
        <div class="ptz-pad">
          <button class="btn btn-ghost" data-vx="-0.5" data-vy="0.5">↖</button>
          <button class="btn btn-ghost" data-vx="0" data-vy="0.5">↑</button>
          <button class="btn btn-ghost" data-vx="0.5" data-vy="0.5">↗</button>
          <button class="btn btn-ghost" data-vx="-0.5" data-vy="0">←</button>
          <button class="btn btn-ghost" disabled>·</button>
          <button class="btn btn-ghost" data-vx="0.5" data-vy="0">→</button>
          <button class="btn btn-ghost" data-vx="-0.5" data-vy="-0.5">↙</button>
          <button class="btn btn-ghost" data-vx="0" data-vy="-0.5">↓</button>
          <button class="btn btn-ghost" data-vx="0.5" data-vy="-0.5">↘</button>
        </div>
        <div class="ptz-col">
          <div class="ptz-row">
            <span class="text-sm muted">zoom</span>
            <button class="btn btn-ghost" data-vz="-0.5">−</button>
            <button class="btn btn-ghost" data-vz="0.5">+</button>
          </div>
          <div class="ptz-row">
            <select id="ptz-preset-select">{forEach presets presetOption}</select>
            <button class="btn btn-ghost" id="ptz-preset-go">go</button>
            <button class="btn btn-ghost" id="ptz-preset-save">save</button>
            <button class="btn btn-ghost" id="ptz-preset-del">delete</button>
            <a class="btn btn-ghost" href={presetsUrl}>manage</a>
          </div>
          <div class="ptz-row">
            <button class="btn" id="ptz-home">⌂ home</button>
            <button class="btn" id="ptz-stop">⏹ stop</button>
          </div>
        </div>
      </div>
    </div>
  </aside>
|]
  where
    cid = tshow (camera |> get #id)
    presetsUrl = "/PtzPresets?ptzCameraId=" <> cid
    presetOption preset =
      [hsx|<option value={token} data-preset-id={pid}>{label}</option>|]
      where
        token = fromMaybe "" preset.onvifToken
        pid = tshow (preset |> get #id)
        label = (if preset.isHome then "⌂ " else "") <> preset.name
