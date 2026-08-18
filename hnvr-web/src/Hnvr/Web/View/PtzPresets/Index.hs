{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /PtzPresets — per-camera preset list + create/goto/home/delete
-- forms (Phase 5, design 05 §"Preset management").
module Hnvr.Web.View.PtzPresets.Index
  ( IndexView (..),
  )
where

import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ModelSupport (Id' (Id))
import IHP.ViewPrelude

data IndexView = IndexView
  { camera :: Camera,
    presets :: [PtzPreset]
  }

instance View IndexView where
  html IndexView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>PTZ presets — {camera.name}</h1>
          <div class="subtitle">
            <a href={showUrl}>{camera.slug}</a> · saved positions on the camera
          </div>
        </div>
      </div>

      <div class="card">
        <div class="card-header"><span>save current position as preset</span></div>
        <form method="POST" action={createUrl} style="padding: 0.75rem 1rem; display: flex; gap: 0.5rem; align-items: center">
          <input class="input" type="text" name="preset_name" placeholder="preset name" required="required" />
          <button class="btn" type="submit">Save preset</button>
        </form>
      </div>

      <div class="card">
        <div class="card-header"><span>presets</span></div>
        <table class="table">
          <thead>
            <tr>
              <th>Name</th>
              <th>ONVIF token</th>
              <th>Home</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {forEach presets renderPreset}
          </tbody>
        </table>
      </div>
    |]
    where
      camIdText = tshow (camera |> get #id)
      showUrl = "/ShowCamera?cameraId=" <> camIdText
      createUrl = "/CreatePtzPreset?ptzCameraId=" <> camIdText

      renderPreset preset =
        [hsx|
        <tr>
          <td>{preset.name}</td>
          <td class="mono">{tokenCell preset.onvifToken}</td>
          <td>{homeBadge preset.isHome}</td>
          <td>
            <form method="POST" action={gotoUrl} style="display:inline">
              <button class="btn btn-ghost" type="submit">go</button>
            </form>
            <form method="POST" action={homeUrl} style="display:inline">
              <button class="btn btn-ghost" type="submit">make home</button>
            </form>
            <form method="POST" action={purgeUrl} style="display:inline">
              <button class="btn btn-ghost" type="submit">delete</button>
            </form>
          </td>
        </tr>
      |]
        where
          pid = tshow (preset |> get #id)
          gotoUrl = "/GotoPtzPreset?ptzPresetId=" <> pid
          homeUrl = "/HomePtzPreset?ptzPresetId=" <> pid
          purgeUrl = "/PurgePtzPreset?ptzPresetId=" <> pid

      tokenCell (Just t) = t
      tokenCell Nothing = "—"

      homeBadge True = [hsx|<span class="badge badge-info">home</span>|]
      homeBadge False = [hsx|<span class="badge badge-mute">—</span>|]
