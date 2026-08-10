{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Cameras.Index (IndexView (..)) where

import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude

newtype IndexView = IndexView
  { cameras :: [Camera]
  }

instance View IndexView where
  html IndexView {..} =
    renderLayout
      [hsx|
      <div class="header">
        <h1>Cameras</h1>
        <a class="btn" href="/NewCamera">New Camera</a>
      </div>
      {renderCameras cameras}
    |]
    where
      renderCameras [] = [hsx|<p>No cameras yet. Click "New Camera" to add one.</p>|]
      renderCameras cs =
        [hsx|
          <table>
            <thead>
              <tr>
                <th>Slug</th>
                <th>Name</th>
                <th>Codec</th>
                <th>Host</th>
                <th>Actions</th>
              </tr>
            </thead>
            <tbody>
              {forEach cs renderCamera}
            </tbody>
          </table>
        |]

      renderCamera camera =
        [hsx|
          <tr>
            <td>{camera.slug}</td>
            <td>{camera.name}</td>
            <td>{tshow camera.codec}</td>
            <td>{fromMaybe "—" camera.assignedHost}</td>
            <td>
              <a href={showUrl}>Show</a>
              ·
              <a href={editUrl}>Edit</a>
            </td>
          </tr>
        |]
        where
          cid = tshow (camera |> get #id)
          showUrl = "/ShowCamera?cameraId=" <> cid
          editUrl = "/EditCamera?cameraId=" <> cid
