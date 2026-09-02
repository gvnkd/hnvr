{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Dashboard.Index (IndexView (..)) where

import qualified Data.List as List
import Data.Time.Clock (UTCTime)
import Generated.Types
import Hnvr.Core.Authz (CameraAction (..), PageKind (..), cameraAllowed, pageAllowed)
import Hnvr.Core.CameraStatus (CameraStatus (..))
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Web.Auth ()
import Hnvr.Web.Authz (currentRoleSet)
import Hnvr.Web.BasePath (urlFor)
import Hnvr.Web.CameraStatus (cameraStatusFor)
import Hnvr.Web.View.Layout (renderLayout)
import Hnvr.Web.View.PtzPanel (ptzPanel)
import IHP.ModelSupport (Id' (Id))
import IHP.ViewPrelude

data IndexView = IndexView
  { cameras :: [Camera],
    hosts :: [Host],
    ptzPresets :: [PtzPreset],
    now :: UTCTime
  }

instance View IndexView where
  html IndexView {..} =
    renderLayout
      [hsx|
      {renderCameras cameras}

      <div id="live-overlay" class="live-overlay" hidden>
        <div class="live-overlay-panel">
          <div class="live-overlay-head">
            <span class="led led-warn"></span>
            <span class="slug"></span>
            <span class="live-overlay-status">
              <span class="live-overlay-status-text">Connecting…</span>
            </span>
            <span class="spacer"></span>
            <button class="btn btn-ghost btn-sm" data-ptz-toggle="1" hidden>PTZ</button>
            <button class="btn btn-ghost btn-sm" data-live-fullscreen="1">fullscreen</button>
            <button class="btn btn-ghost btn-sm" data-live-close="1">close ✕</button>
          </div>
          <div class="live-overlay-video">
            <video autoplay muted controls></video>
            <button class="btn btn-ghost btn-sm zoompan-fs" data-zoompan-fs="1">fullscreen</button>
          </div>
          <div class="live-overlay-ptz"></div>
        </div>
      </div>

      {forEach ptzCams renderPtzTemplate}
      <script src={urlFor "/static/ptz.js"}></script>
    |]
    where
      -- PTZ drawer templates only for logged-in operators with a PTZ
      -- grant on the camera (design_docs/13): the dashboard is
      -- anonymous-readable and the PTZ POST endpoints are role-gated,
      -- so visitors without ptz_move/ptz_preset get no PTZ markup at
      -- all (app.js also keeps the overlay toggle hidden when no
      -- template exists for the opened camera).
      ptzCams
        | isJust (currentUserOrNothing :: Maybe User) =
            filter ptzAllowed cameras
        | otherwise = []
      ptzAllowed cam =
        cam.ptzEnabled
          && ( cameraAllowed rs PtzMove (camId cam)
                 || cameraAllowed rs PtzPresetOp (camId cam)
             )
      rs = currentRoleSet
      camId c = case c |> get #id of Id u -> CameraId u

      -- Per-PTZ-camera panel templates; app.js clones the matching
      -- template into the overlay's .live-overlay-ptz slot on open.
      renderPtzTemplate cam =
        [hsx|
          <template data-ptz-for={cam.slug}>{ptzPanel cam (presetsFor cam)}</template>
        |]
      presetsFor cam = filter (\p -> p.cameraId == camUuid cam) ptzPresets
      camUuid c = case c |> get #id of Id u -> u

      renderCameras [] = [hsx|<div class="empty"><span class="empty-icon">⌖</span>No cameras yet. Add some via hnvr-admin.</div>|]
      renderCameras cs =
        [hsx|
          <div class="cam-grid">
            {forEach cs renderCamera}
          </div>
        |]
      renderCamera cam = card
        where
          cid = tshow (cam |> get #id)
          frameUrl = urlFor ("/debug-frame/" <> cid)
          archiveUrl = urlFor ("/PlayerArchive?cameraId=" <> cid)
          debugUrl = urlFor ("/DebugCamera?cameraId=" <> cid)
          hostLabel = fromMaybe "unassigned" cam.assignedHost
          -- Card links follow the same grants as their targets
          -- (design_docs/13 — hide, don't 403). Camera config moved to
          -- hnvr-admin (M4) — no config link here anymore.
          canArchive = cameraAllowed rs ViewArchive (camId cam)
          canDebug = pageAllowed rs PageSettings
          cardLinks = mconcat (List.intersperse linkSep linkItems)
          linkSep = [hsx|<span class="faint">·</span>|]
          linkItems =
            [[hsx|<a href={archiveUrl}>archive</a>|] | canArchive]
              ++ [[hsx|<a href={debugUrl}>debug</a>|] | canDebug]
          -- REC only while the assigned host reports this camera's
          -- worker as Running; anything else gets an explicit status
          -- badge (was: unconditional static REC, even for dead
          -- cameras). After page load the badge is JS-owned: the
          -- frame poller rewrites it to REC on signal and to
          -- NO SIGNAL on loss (change-only writes in app.js
          -- initLiveFrames) — a server-rendered badge can't track
          -- liveness on its own.
          statusBadge = case cameraStatusFor hosts now cam of
            CSRecording -> [hsx|<span class="badge badge-rec cam-badge-status"><span class="led led-rec"></span>REC</span>|]
            CSStarting -> [hsx|<span class="badge badge-warn cam-badge-status">STARTING</span>|]
            CSReconnecting -> [hsx|<span class="badge badge-warn cam-badge-status">RECONNECTING</span>|]
            CSFailed -> [hsx|<span class="badge badge-danger cam-badge-status">FAILED</span>|]
            CSHostDown -> [hsx|<span class="badge badge-danger cam-badge-status">HOST DOWN</span>|]
            CSNotRunning -> [hsx|<span class="badge badge-mute cam-badge-status">STOPPED</span>|]
            CSUnassigned -> [hsx|<span class="badge badge-mute cam-badge-status">UNASSIGNED</span>|]
            CSDisabled -> [hsx|<span class="badge badge-mute cam-badge-status">DISABLED</span>|]
          card =
            [hsx|
              <div class="cam-card" data-slug={cam.slug} data-cam-id={cid} title="Click for live view">
                <div class="cam-live" data-frame-url={frameUrl}>
                  <img alt="" />
                  <img alt="" />
                  <div class="scanline"></div>
                  <div class="cam-flags">
                    {statusBadge}
                    <span class="badge badge-mute">{hostLabel}</span>
                  </div>
                  <div class="cam-placeholder">
                    <span style="font-size: 22px;">◉</span>
                    <span>no signal</span>
                  </div>
                </div>
                <div class="cam-body">
                  <span class="slug">{cam.slug}</span>
                  <span class="links">{cardLinks}</span>
                </div>
              </div>
            |]
