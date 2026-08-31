{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /Timeline shell (design_docs/12-timeline-archive.md): range
-- presets + custom window, ONE archive player (camera dropdown +
-- thumbnail scrubbing → hls.js playback on cursor release, admin
-- purge), and the canvas timeline. All behavior lives in
-- /static/timeline.js, driven by the @data-tl-*@ attributes here.
module Hnvr.Web.View.Timeline.Index
  ( IndexView (..),
  )
where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Generated.Types
import Hnvr.Core.Authz (CameraAction (..), cameraAllowed)
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Web.Authz (currentRoleSet)
import Hnvr.Web.View.Layout (renderLayout)
import Hnvr.Web.View.Time (tzTime)
import IHP.ModelSupport (Id' (Id))
import IHP.ViewPrelude

data IndexView = IndexView
  { cameras :: [Camera],
    winFrom :: UTCTime,
    winTo :: UTCTime,
    cursor :: UTCTime
  }

instance View IndexView where
  html IndexView {..} =
    renderLayout
      [hsx|
        <div class="section-h">Archive timeline</div>

        <div class="card mb-4 tl-shell" data-tl-shell>
          <div class="card-body tl-shell-body">
            <div class="tl-rangebar">
              <div class="dropdown" data-dropdown="1">
                <button class="btn btn-ghost btn-sm" data-dropdown-button="1" aria-expanded="false" type="button">
                  ◷ Range: {rangeLabel} ▾
                </button>
                <div class="dropdown-menu drop-down" hidden>
                  {presetItem 3600 "1 hour"}
                  {presetItem (6 * 3600) "6 hours"}
                  {presetItem (24 * 3600) "24 hours"}
                </div>
              </div>
              <form method="GET" action="/Timeline" class="tl-custom">
                <input class="input" type="datetime-local" name="from" data-tz-dt="1" value={dtLocal winFrom} />
                <span class="muted">→</span>
                <input class="input" type="datetime-local" name="to" data-tz-dt="1" value={dtLocal winTo} />
                <button class="btn btn-ghost" type="submit">Apply</button>
              </form>
              <div class="tl-rangebar-end">
                <span class="tl-cursor-label muted">cursor: <span data-tl-cursor-label>{tzTime cursor}</span></span>
                <button class="btn btn-ghost btn-sm" data-tl-fs title="Expand player + timeline fullscreen">fullscreen</button>
              </div>
            </div>
            {playerBody}
            <div
              class="tl-canvas-wrap"
              data-timeline
              data-from={iso winFrom}
              data-to={iso winTo}
              data-cursor={iso cursor}
            >
              <canvas class="tl-canvas" data-tl-canvas></canvas>
            </div>
            <div class="hint mt-2">
              Pick the camera from the dropdown. Hover or drag the timeline to preview and scrub —
              the player shows the snapshot nearest the cursor; on release the selected camera plays
              from the cursor time. Tap an event marker to jump to it; shift-click (long-press on touch)
              opens its clip.
            </div>
          </div>
        </div>

        <script src="https://cdn.jsdelivr.net/npm/hls.js@1"></script>
        <script src="/static/timeline.js"></script>
      |]
    where
      iso :: UTCTime -> Text
      iso = T.pack . iso8601Show

      -- \| UTC @YYYY-MM-DDTHH:MM@ — the data-tz-dt contract: app.js
      -- converts to the viewer's zone on load and back to UTC on
      -- submit; the server parses it via 'parseWhen'.
      dtLocal :: UTCTime -> Text
      dtLocal = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M"

      -- \| Range presets keep the cursor timestamp: the new window is
      -- centered on it (half the range each side). The centered window
      -- may extend past now (the future half is simply empty — the
      -- controller allows @to@ up to 24 h ahead).
      presetItem :: NominalDiffTime -> Text -> Html
      presetItem width label =
        [hsx|<a class={cls} href={href}>{label}</a>|]
        where
          half = width / 2
          f = addUTCTime (-half) cursor
          t = addUTCTime half cursor
          href = "/Timeline?from=" <> iso f <> "&to=" <> iso t <> "&t=" <> iso cursor
          cls = (if active then "dropdown-item is-active" else "dropdown-item") :: Text
          active = abs (diffUTCTime winTo winFrom - width) < 60

      rangeLabel :: Text
      rangeLabel
        | isWidth 3600 = "1h"
        | isWidth (6 * 3600) = "6h"
        | isWidth (24 * 3600) = "24h"
        | otherwise = "custom"
        where
          isWidth w = abs (diffUTCTime winTo winFrom - w) < 60

      -- Single archive player: camera dropdown + one video surface.
      -- Exactly one camera streams at a time (N concurrent hls.js
      -- instances was too laggy); timeline.js owns switching.
      playerBody =
        if null cameras
          then mempty
          else
            [hsx|
              <div class="tl-player">
                <div class="tl-player-bar">
                  <label class="tl-player-cam text-sm">
                    <span class="muted">Camera:</span>
                    <select class="input" data-tl-camera>
                      {forEach cameras camOption}
                    </select>
                  </label>
                    <span class="muted text-sm" data-tl-state>idle</span>
                    <button class="btn btn-ghost btn-sm" data-tl-prev-event title="Jump to the previous event">◀ event</button>
                    <button class="btn btn-ghost btn-sm" data-tl-next-event title="Jump to the next event">event ▶</button>
                    {purgeForm}
                </div>
                <div class="tl-player-body">
                  <img data-tl-thumb alt="" hidden />
                  <div class="tl-player-placeholder" data-tl-placeholder>—</div>
                  <button class="btn btn-ghost btn-sm zoompan-fs" data-zoompan-fs="1">fullscreen</button>
                </div>
              </div>
            |]

      camOption camera =
        [hsx|<option value={camIdText camera}>{camera.slug}</option>|]

      camIdText camera = tshow (camera |> get #id)

      -- Purge requires the per-camera purge_archive grant
      -- (design_docs/13; was: is_admin). The form carries the first
      -- granted camera; timeline.js rewrites action + data-confirm on
      -- dropdown change and hides the button when the active camera
      -- isn't in data-purge-cams.
      purgeForm =
        case purgeCams of
          firstCam : _ ->
            [hsx|
              <form method="POST" action={purgeAction firstCam} class="tl-purge-form" data-tl-purge
                    data-confirm={confirmText firstCam} data-purge-cams={purgeCamIds}>
                <input type="hidden" name="purgeFrom" value={iso winFrom} />
                <input type="hidden" name="purgeTo" value={iso winTo} />
                <button type="submit" class="link-button tl-purge-btn" title="Purge recordings in window">purge</button>
              </form>
            |]
          [] -> mempty
      purgeCams = filter (cameraAllowed rs PurgeArchive . camId) cameras
      purgeCamIds = T.intercalate "," (map camIdText purgeCams)
      rs = currentRoleSet
      camId c = case c |> get #id of Id u -> CameraId u
      purgeAction camera = "/PurgeRecording?purgeCameraId=" <> camIdText camera
      confirmText camera = "Purge " <> camera.slug <> " recordings in the current window?"
