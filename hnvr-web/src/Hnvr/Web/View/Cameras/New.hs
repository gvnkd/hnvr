{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Cameras.New (NewView (..)) where

import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude

newtype NewView = NewView
  { camera :: Camera
  }

instance View NewView where
  html NewView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>New Camera</h1>
          <div class="subtitle">Register an RTSP source for 24/7 recording</div>
        </div>
        <div class="actions">
          <a class="btn btn-ghost" href="/Cameras">← Back</a>
        </div>
      </div>

      <div class="card">
        <div class="card-header">Camera definition</div>
        <div class="card-body">
          {renderForm camera}
        </div>
      </div>
    |]
    where
      renderForm camera =
        [hsx|
          <form class="form" method="POST" action="/CreateCamera">
            {textFieldFor "slug" "Slug" camera.slug "Unique handle, e.g. floor_2_5"}
            {textFieldFor "name" "Name" camera.name "Human-friendly label"}
            {textFieldFor "rtspUrl" "RTSP URL (main)" camera.rtspUrl "Main stream — typically high-res"}
            <div class="field">
              <label>RTSP transport</label>
              <select name="rtspTransport">
                <option value="tcp" selected={camera.rtspTransport == "tcp"}>tcp (default; recommended for LAN)</option>
                <option value="udp" selected={camera.rtspTransport == "udp"}>udp (use if camera rejects TCP SETUP)</option>
              </select>
            </div>
            {textFieldFor "rtspSubUrl" "RTSP URL (sub, optional)" (fromMaybe "" camera.rtspSubUrl) "Analysis stream — lower-res"}
            {textFieldFor "username" "Username" (fromMaybe "" camera.username) "RTSP credentials"}
            {textFieldFor "password" "Password (stored encrypted)" ("" :: Text) "AES-256-GCM at rest"}
            {textFieldFor "host" "Host IP" (fromMaybe "" camera.host) "Camera hostname or IP"}
            {textFieldFor "port" "Port" (tshow camera.port) "RTSP port (default 554)"}
            {textFieldFor "retentionHours" "Full-record retention (hours)" (tshow camera.retentionHours) "Event clips have their own per-rule retention"}

            <div class="field">
              <label>Codec</label>
              <select name="codec">
                <option value="unknown" selected={camera.codec == Unknown}>unknown</option>
                <option value="h264" selected={camera.codec == H264}>h264</option>
                <option value="hevc" selected={camera.codec == Hevc}>hevc</option>
              </select>
            </div>

            <div class="field">
              <label>Analysis model</label>
              <select name="modelName">
                <option value="yolov8n-320" selected={camera.modelName == "yolov8n-320"}>yolov8n-320 (default)</option>
                <option value="yolov8s-640" selected={camera.modelName == "yolov8s-640"}>yolov8s-640 (hnvr-2 only)</option>
              </select>
              <div class="hint">Resolved to &lt;model-dir&gt;/&lt;name&gt;.onnx on the assigned host</div>
            </div>

            <div class="flex items-center gap-2 mt-6">
              <button class="btn btn-primary" type="submit">Create Camera</button>
              <a class="btn btn-ghost" href="/Cameras">Cancel</a>
            </div>
          </form>
        |]

      textFieldFor name' label' value' hint' =
        [hsx|
          <div class="field">
            <label>{label'}</label>
            <input class="input" type="text" name={name'} value={value'} />
            <div class="hint">{hint'}</div>
          </div>
        |]
