{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Cameras.Edit (EditView (..)) where

import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude

newtype EditView = EditView
  { camera :: Camera
  }

instance View EditView where
  html EditView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Edit · <span class="font-mono text-signal-info">{camera.slug}</span></h1>
          <div class="subtitle">RTSP source configuration</div>
        </div>
        <div class="actions">
          <a class="btn btn-ghost" href={showUrl}>← Back</a>
        </div>
      </div>

      <div class="card">
        <div class="card-header">Camera definition</div>
        <div class="card-body">{renderForm camera}</div>
      </div>

      <div class="card mt-4">
        <div class="card-header">Stream probe</div>
        <div class="card-body">
          <p class="text-sm text-zinc-400 mb-4">
            Probe the main RTSP URL (and the sub URL when present) with
            <span class="mono">ffprobe</span> to fill codec + sub-stream
            fields automatically.
          </p>
          <form method="POST" action={probeUrl}>
            <button class="btn" type="submit">Probe Streams</button>
          </form>
        </div>
      </div>
    |]
    where
      cid = tshow (camera |> get #id)
      showUrl = "/ShowCamera?cameraId=" <> cid
      probeUrl = "/ProbeCamera?cameraId=" <> cid

      renderForm camera =
        [hsx|
          <form class="form" method="POST" action={updateUrl camera}>
            {textFieldFor "slug" "Slug" camera.slug ""}
            {textFieldFor "name" "Name" camera.name ""}
            {textFieldFor "rtspUrl" "RTSP URL (main)" camera.rtspUrl ""}
            {textFieldFor "rtspSubUrl" "RTSP URL (sub, optional)" (fromMaybe "" camera.rtspSubUrl) ""}
            {textFieldFor "username" "Username" (fromMaybe "" camera.username) ""}
            {textFieldFor "password" "Password (blank = keep current)" ("" :: Text) "Stored encrypted; leave blank to retain existing value."}
            {textFieldFor "host" "Host IP" (fromMaybe "" camera.host) ""}
            {textFieldFor "port" "Port" (tshow camera.port) ""}

            <div class="field">
              <label>Codec</label>
              <select name="codec">
                <option value="unknown" selected={camera.codec == Unknown}>unknown</option>
                <option value="h264" selected={camera.codec == H264}>h264</option>
                <option value="hevc" selected={camera.codec == Hevc}>hevc</option>
              </select>
            </div>

            <div class="flex items-center gap-2 mt-6">
              <button class="btn btn-primary" type="submit">Save Changes</button>
              <a class="btn btn-ghost" href={showUrl}>Cancel</a>
            </div>
          </form>
        |]

      updateUrl cam = "/UpdateCamera?cameraId=" <> tshow (cam |> get #id)

      textFieldFor name' label' value' hint' =
        [hsx|
          <div class="field">
            <label>{label'}</label>
            <input class="input" type="text" name={name'} value={value'} />
            <div class="hint">{hint'}</div>
          </div>
        |]
