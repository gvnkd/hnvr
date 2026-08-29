{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Cameras.Show (ShowView (..)) where

import Data.Time.Clock (UTCTime)
import Generated.Types
import Hnvr.Core.Authz (CameraAction (..), PageKind (..), cameraAllowed, pageAllowed)
import Hnvr.Core.CameraStatus (CameraStatus (..))
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Web.Authz (currentRoleSet)
import Hnvr.Web.CameraStatus (cameraStatusFor)
import Hnvr.Web.View.Layout (renderLayout)
import Hnvr.Web.View.Time (tzTime)
import IHP.ModelSupport (Id' (Id))
import IHP.ViewPrelude

data ShowView = ShowView
  { camera :: Camera,
    drifts :: [CameraDrift],
    hosts :: [Host],
    now :: UTCTime
  }

instance View ShowView where
  html ShowView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>
            <span class={hdrLedClass}></span>
            <span class="font-mono">{camera.slug}</span>
            {statusBadge}
          </h1>
          <div class="subtitle">{camera.name} · {codecBadge camera.codec}</div>
        </div>
        <div class="actions">
          {toggleBtn}
          {editBtn}
          {debugBtn}
          {newRuleBtn}
          {archiveBtn}
        </div>
      </div>

      <div class="card">
        <div class="card-header">Configuration</div>
        <table class="table">
          <tbody>
            {kvRow "Name" camera.name}
            {kvRow "RTSP (main)" camera.rtspUrl}
            {kvRow "RTSP transport" camera.rtspTransport}
            {kvRow "RTSP (sub)" (fromMaybe "—" camera.rtspSubUrl)}
            {kvRow "Host" (fromMaybe "—" camera.host)}
            {kvRow "Codec" (codecBadge camera.codec)}
            {kvRow "Substream codec" (tshow camera.substreamCodec)}
            {kvRow "Substream res" (tshow camera.substreamWidth <> "×" <> tshow camera.substreamHeight)}
            {kvRow "Record audio" (tshow camera.recordAudio)}
            {kvRow "Analysis FPS" (tshow camera.analysisFps)}
            {kvRow "Enabled" (tshow camera.enabled)}
            {kvRow "Retention hours" (tshow camera.retentionHours)}
            {kvRow "Assigned host" (fromMaybe "—" camera.assignedHost)}
            {kvRow "Manual assign" (tshow camera.manualAssign)}
            {kvRow "ONVIF port" (maybe "unmanaged" tshow camera.onvifPort)}
          </tbody>
        </table>
      </div>

      {renderDrift camera drifts}

      {assignCard}
      |]
    where
      cid = tshow (camera |> get #id)
      editUrl = "/EditCamera?cameraId=" <> cid
      debugUrl = "/DebugCamera?cameraId=" <> cid
      newRuleUrl = "/NewRule?ruleCameraId=" <> cid
      archiveUrl = "/PlayerArchive?cameraId=" <> cid
      assignUrl = "/AssignCamera?cameraId=" <> cid
      toggleUrl = "/ToggleCameraEnabled?cameraId=" <> cid
      toggleLabel = if camera.enabled then "Disable camera" else "Enable camera"

      -- Roles & ACL (design_docs/13): action buttons render only with
      -- the matching per-camera grant (controllers enforce anyway).
      rs = currentRoleSet
      camId = case camera |> get #id of Id u -> CameraId u
      canEdit = cameraAllowed rs EditConfig camId
      toggleBtn =
        if not canEdit
          then mempty
          else
            [hsx|
              <form method="POST" action={toggleUrl} style="display:contents">
                <button type="submit" class="btn">{toggleLabel}</button>
              </form>
            |]
      editBtn =
        if canEdit
          then [hsx|<a class="btn" href={editUrl}>Edit</a>|]
          else mempty
      debugBtn =
        if pageAllowed rs PageSettings
          then [hsx|<a class="btn" href={debugUrl}>Debug stream</a>|]
          else mempty
      newRuleBtn =
        if cameraAllowed rs ManageEvents camId
          then [hsx|<a class="btn" href={newRuleUrl}>New rule</a>|]
          else mempty
      archiveBtn =
        if cameraAllowed rs ViewArchive camId
          then [hsx|<a class="btn btn-primary" href={archiveUrl}>Watch archive</a>|]
          else mempty
      assignCard =
        if not canEdit
          then mempty
          else
            [hsx|
              <div class="card mt-4">
                <div class="card-header">Manual assignment</div>
                <div class="card-body">
                  <form class="form" method="POST" action={assignUrl}>
                    <div class="field">
                      <label for="assigned_host">Override assigned host (blank = auto)</label>
                      <input class="input" id="assigned_host" name="assigned_host" value={fromMaybe "" camera.assignedHost} placeholder="hnvr-1" />
                      <div class="hint">Setting a host marks the camera as manually assigned; clearing it returns the camera to auto-assignment.</div>
                    </div>
                    <button class="btn btn-primary" type="submit">Save assignment</button>
                  </form>
                </div>
              </div>
            |]

      kvRow k v =
        [hsx|
          <tr class="kv">
            <th>{k}</th>
            <td>{v}</td>
          </tr>
        |]

      renderDrift cam _ | isNothing cam.onvifPort = mempty
      renderDrift _ [] =
        [hsx|
          <div class="card mt-4">
            <div class="card-header">ONVIF drift</div>
            <div class="card-body">
              <span class="badge badge-ok">SYNCED</span>
              <span class="text-sm muted">camera matches desired encoder settings</span>
            </div>
          </div>
        |]
      renderDrift _ ds =
        [hsx|
          <div class="card mt-4">
            <div class="card-header">ONVIF drift <span class="badge badge-warn">{tshow (length ds)}</span></div>
            <table class="table">
              <thead>
                <tr><th>Config</th><th>Field</th><th>Desired</th><th>Observed</th><th>First seen</th><th>Last seen</th></tr>
              </thead>
              <tbody>{forEach ds renderDriftRow}</tbody>
            </table>
          </div>
        |]

      renderDriftRow d =
        [hsx|
          <tr>
            <td class="mono">{d.configName}</td>
            <td class="mono">{d.fieldName}</td>
            <td class="mono">{d.desired}</td>
            <td class="mono">{d.observed}</td>
            <td class="mono">{tzTime d.firstSeenAt}</td>
            <td class="mono">{tzTime d.lastSeenAt}</td>
          </tr>
        |]

      codecBadge Unknown = [hsx|<span class="badge badge-mute">UNKNOWN</span>|]
      codecBadge H264 = [hsx|<span class="badge badge-info">H264</span>|]
      codecBadge Hevc = [hsx|<span class="badge badge-warn">HEVC</span>|]

      camStatus = cameraStatusFor hosts now camera
      hdrLedClass = case camStatus of
        CSRecording -> "led led-rec" :: Text
        _ -> "led led-off"
      statusBadge = case camStatus of
        CSRecording -> mempty
        CSStarting -> [hsx|<span class="badge badge-warn">STARTING</span>|]
        CSReconnecting -> [hsx|<span class="badge badge-warn">RECONNECTING</span>|]
        CSFailed -> [hsx|<span class="badge badge-danger">FAILED</span>|]
        CSHostDown -> [hsx|<span class="badge badge-danger">HOST DOWN</span>|]
        CSNotRunning -> [hsx|<span class="badge badge-mute">STOPPED</span>|]
        CSUnassigned -> [hsx|<span class="badge badge-mute">UNASSIGNED</span>|]
        CSDisabled -> [hsx|<span class="badge badge-mute">DISABLED</span>|]
