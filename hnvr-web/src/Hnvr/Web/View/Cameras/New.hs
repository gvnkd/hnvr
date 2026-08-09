{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}

module Hnvr.Web.View.Cameras.New (NewView (..)) where

import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude

data NewView = NewView
  { camera :: Camera
  }

instance View NewView where
  html NewView {..} = renderLayout
    [hsx|
      <div class="header">
        <h1>New Camera</h1>
      </div>
      {renderForm camera}
    |]
    where
      renderForm camera =
        [hsx|
          <form class="stacked" method="POST" action="/cameras">
            {textFieldFor "slug" "Slug" camera.slug}
            {textFieldFor "name" "Name" camera.name}
            {textFieldFor "rtspUrl" "RTSP URL (main)" camera.rtspUrl}
            {textFieldFor "rtspSubUrl" "RTSP URL (sub, optional)" (fromMaybe "" camera.rtspSubUrl)}
            {textFieldFor "username" "Username" (fromMaybe "" camera.username)}
            {textFieldFor "password" "Password (stored encrypted)" ("" :: Text)}
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
            <button class="btn" type="submit">Create Camera</button>
          </form>
        |]

      textFieldFor name' label' value' =
        [hsx|
          <div class="field-row">
            <label>{label'}</label>
            <input type="text" name={name'} value={value'} />
          </div>
        |]
