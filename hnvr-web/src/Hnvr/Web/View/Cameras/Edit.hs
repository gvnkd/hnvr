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
      <div class="header">
        <h1>Edit {camera.slug}</h1>
      </div>
      {renderForm camera}
      <hr />
      <h3>Probe</h3>
      <p>Probe the main RTSP URL (and the sub URL when present) with ffprobe
        to fill codec + sub-stream fields automatically.</p>
      <form method="POST" action={probeUrl}>
        <button class="btn" type="submit">Probe Streams</button>
      </form>
    |]
    where
      probeUrl = "/ProbeCamera?cameraId=" <> tshow (camera |> get #id)

      renderForm camera =
        [hsx|
          <form class="stacked" method="POST" action={updateUrl camera}>
            {textFieldFor "slug" "Slug" camera.slug}
            {textFieldFor "name" "Name" camera.name}
            {textFieldFor "rtspUrl" "RTSP URL (main)" camera.rtspUrl}
            {textFieldFor "rtspSubUrl" "RTSP URL (sub, optional)" (fromMaybe "" camera.rtspSubUrl)}
            {textFieldFor "username" "Username" (fromMaybe "" camera.username)}
            {textFieldFor "password" "Password (stored encrypted; blank = keep)" ("" :: Text)}
            {textFieldFor "host" "Host IP" (fromMaybe "" camera.host)}
            {textFieldFor "port" "Port" (tshow camera.port)}
            <div class="field-row">
              <label>Codec</label>
              <select name="codec">
                <option value="unknown" selected={camera.codec == Unknown}>unknown</option>
                <option value="h264" selected={camera.codec == H264}>h264</option>
                <option value="hevc" selected={camera.codec == Hevc}>hevc</option>
              </select>
            </div>
            <button class="btn" type="submit">Save Changes</button>
          </form>
        |]

      updateUrl cam = "/UpdateCamera?cameraId=" <> tshow (cam |> get #id)

      textFieldFor name' label' value' =
        [hsx|
          <div class="field-row">
            <label>{label'}</label>
            <input type="text" name={name'} value={value'} />
          </div>
        |]
