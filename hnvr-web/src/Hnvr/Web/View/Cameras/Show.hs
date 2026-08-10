{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Cameras.Show (ShowView (..)) where

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
        <h1>{camera.slug}</h1>
        <span>
          <a class="btn" href={editUrl}>Edit</a>
          <a class="btn" href={archiveUrl}>Watch archive</a>
        </span>
      </div>
      <table>
        <tr><th>Name</th><td>{camera.name}</td></tr>
        <tr><th>RTSP (main)</th><td>{camera.rtspUrl}</td></tr>
        <tr><th>RTSP (sub)</th><td>{fromMaybe "—" camera.rtspSubUrl}</td></tr>
        <tr><th>Host</th><td>{fromMaybe "—" camera.host}</td></tr>
        <tr><th>Port</th><td>{tshow camera.port}</td></tr>
        <tr><th>Codec</th><td>{tshow camera.codec}</td></tr>
        <tr><th>Substream codec</th><td>{tshow camera.substreamCodec}</td></tr>
        <tr><th>Substream res</th><td>{tshow camera.substreamWidth}×{tshow camera.substreamHeight}</td></tr>
        <tr><th>Record audio</th><td>{tshow camera.recordAudio}</td></tr>
        <tr><th>Analysis FPS</th><td>{tshow camera.analysisFps}</td></tr>
        <tr><th>Enabled</th><td>{tshow camera.enabled}</td></tr>
        <tr><th>Retention days</th><td>{tshow camera.retentionDays}</td></tr>
        <tr><th>Assigned host</th><td>{fromMaybe "—" camera.assignedHost}</td></tr>
        <tr><th>Manual assign</th><td>{tshow camera.manualAssign}</td></tr>
      </table>

      <h2>Manual assignment</h2>
      <form class="stacked" method="POST" action={assignUrl}>
        <div class="field-row">
          <label for="assigned_host">Override assigned host (blank = auto)</label>
          <input id="assigned_host" name="assigned_host" value={fromMaybe "" camera.assignedHost} placeholder="hnvr-1" />
        </div>
        <button class="btn" type="submit">Save assignment</button>
      </form>
    |]
    where
      cid = tshow (camera |> get #id)
      editUrl = "/cameras/" <> cid <> "/edit"
      archiveUrl = "/cameras/" <> cid <> "/archive"
      assignUrl = "/cameras/" <> cid <> "/assign"
