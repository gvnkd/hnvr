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
import Hnvr.Web.View.Layout (renderLayout)
import Hnvr.Web.View.Time (tzTime)
import IHP.ViewPrelude

data IndexView = IndexView
  { cameras :: [Camera],
    winFrom :: UTCTime,
    winTo :: UTCTime,
    cursor :: UTCTime,
    isAdmin :: Bool
  }

instance View IndexView where
  html IndexView {..} =
    renderLayout
      [hsx|
        <div class="section-h">Archive timeline</div>

        <div class="card mb-4">
          <div class="card-body tl-rangebar">
            <span class="muted text-sm">Range:</span>
            {presetLink 3600 "1h"}
            {presetLink (6 * 3600) "6h"}
            {presetLink (24 * 3600) "24h"}
            <form method="GET" action="/Timeline" class="tl-custom">
              <input class="input" type="datetime-local" name="from" data-tz-dt="1" value={dtLocal winFrom} />
              <span class="muted">→</span>
              <input class="input" type="datetime-local" name="to" data-tz-dt="1" value={dtLocal winTo} />
              <button class="btn btn-ghost" type="submit">Apply</button>
            </form>
            <span class="tl-cursor-label muted">cursor: <span data-tl-cursor-label>{tzTime cursor}</span></span>
          </div>
        </div>

        {playerCard}

        <div class="card mt-4">
          <div class="card-body">
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
              Pick the camera from the dropdown. Drag the cursor to scrub — the player shows the
              snapshot nearest the cursor; on release the selected camera plays from the cursor time.
              Click an event marker to jump to it; shift-click opens its clip.
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

      presetLink :: NominalDiffTime -> Text -> Html
      presetLink width label =
        [hsx|<a class={cls} href={href}>{label}</a>|]
        where
          href = "/Timeline?from=" <> iso (addUTCTime (-width) winTo) <> "&to=" <> iso winTo
          active = abs (diffUTCTime winTo winFrom - width) < 60
          cls = (if active then "btn btn-primary" else "btn btn-ghost") :: Text

      -- Single archive player: camera dropdown + one video surface.
      -- Exactly one camera streams at a time (N concurrent hls.js
      -- instances was too laggy); timeline.js owns switching.
      playerCard =
        if null cameras
          then mempty
          else
            [hsx|
              <div class="card mb-4">
                <div class="card-body tl-player">
                  <div class="tl-player-bar">
                    <label class="tl-player-cam text-sm">
                      <span class="muted">Camera:</span>
                      <select class="input" data-tl-camera>
                        {forEach cameras camOption}
                      </select>
                    </label>
                    <span class="muted text-sm" data-tl-state>idle</span>
                    {purgeForm}
                  </div>
                  <div class="tl-player-body">
                    <img data-tl-thumb alt="" hidden />
                    <div class="tl-player-placeholder" data-tl-placeholder>—</div>
                    <button class="btn btn-ghost btn-sm zoompan-fs" data-zoompan-fs="1">fullscreen</button>
                  </div>
                </div>
              </div>
            |]

      camOption camera =
        [hsx|<option value={camIdText camera}>{camera.slug}</option>|]

      camIdText camera = tshow (camera |> get #id)

      -- Admin-only: tombstone the SELECTED camera's recordings across
      -- the CURRENT timeline window. The form carries the first
      -- camera; timeline.js rewrites action + data-confirm when the
      -- dropdown changes. Hidden inputs carry UTC ISO; the controller
      -- redirects back to /Timeline with the window.
      purgeForm =
        case (isAdmin, cameras) of
          (True, firstCam : _) ->
            [hsx|
              <form method="POST" action={purgeAction firstCam} class="tl-purge-form" data-tl-purge
                    data-confirm={confirmText firstCam}>
                <input type="hidden" name="purgeFrom" value={iso winFrom} />
                <input type="hidden" name="purgeTo" value={iso winTo} />
                <button type="submit" class="link-button tl-purge-btn" title="Purge recordings in window">purge</button>
              </form>
            |]
          _ -> mempty
      purgeAction camera = "/PurgeRecording?purgeCameraId=" <> camIdText camera
      confirmText camera = "Purge " <> camera.slug <> " recordings in the current window?"
