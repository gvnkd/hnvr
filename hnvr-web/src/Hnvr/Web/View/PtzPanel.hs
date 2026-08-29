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
-- Callers must only render this for logged-in users with a PTZ grant on
-- the camera. Inside the panel the move pad + zoom + stop render only
-- with @ptz_move@, the preset row + home only with @ptz_preset@
-- (design_docs/13; the POST endpoints enforce the same split).
--
-- No top-level signature: the Html type carries implicit params
-- (pitfall #36), the enclosing view's scope provides them.
module Hnvr.Web.View.PtzPanel
  ( ptzPanel,
  )
where

import Generated.Types
import Hnvr.Core.Authz (CameraAction (..), cameraAllowed)
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Web.Authz (currentRoleSet)
import IHP.ModelSupport (Id' (Id))
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
        {moveSection}
        <div class="ptz-col">
          {presetSection}
        </div>
      </div>
    </div>
  </aside>
|]
  where
    cid = tshow (camera |> get #id)
    presetsUrl = "/PtzPresets?ptzCameraId=" <> cid
    rs = currentRoleSet
    camId = case camera |> get #id of Id u -> CameraId u
    canMove = cameraAllowed rs PtzMove camId
    canPreset = cameraAllowed rs PtzPresetOp camId
    moveSection =
      if not canMove
        then mempty
        else
          [hsx|
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
            <div class="ptz-row">
              <span class="text-sm muted">zoom</span>
              <button class="btn btn-ghost" data-vz="-0.5">−</button>
              <button class="btn btn-ghost" data-vz="0.5">+</button>
            </div>
          |]
    presetSection =
      if not canPreset
        then mempty
        else
          [hsx|
            <div class="ptz-row">
              <select id="ptz-preset-select">{forEach presets presetOption}</select>
              <button class="btn btn-ghost" id="ptz-preset-go">go</button>
              <button class="btn btn-ghost" id="ptz-preset-save">save</button>
              <button class="btn btn-ghost" id="ptz-preset-del">delete</button>
              <a class="btn btn-ghost" href={presetsUrl}>manage</a>
            </div>
            <div class="ptz-row">
              <button class="btn" id="ptz-home">⌂ home</button>
              {stopBtn}
            </div>
          |]
    stopBtn =
      if canMove
        then [hsx|<button class="btn" id="ptz-stop">⏹ stop</button>|]
        else mempty
    presetOption preset =
      [hsx|<option value={token} data-preset-id={pid}>{label}</option>|]
      where
        token = fromMaybe "" preset.onvifToken
        pid = tshow (preset |> get #id)
        label = (if preset.isHome then "⌂ " else "") <> preset.name
