{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /Timeline shell (design_docs/12-timeline-archive.md): range
-- presets + custom window, camera tile grid (thumbnail scrubbing →
-- hls.js playback on cursor release, enable toggle, admin purge), and
-- the canvas timeline. All behavior lives in /static/timeline.js,
-- driven by the @data-tl-*@ attributes here.
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

        <div class="tl-grid" data-tl-grid>
          {forEach cameras tile}
        </div>

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
              Drag the cursor to scrub — tiles show the snapshot nearest the cursor.
              Click a tile to make it the active camera; on release it plays from the cursor time
              while the others keep thumbnails. Click an event marker to jump to it; shift-click opens its clip.
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

      tile camera =
        [hsx|
          <div class="tl-tile" data-tl-tile data-cam-id={camIdText} data-slug={camera.slug}>
            <div class="tl-tile-head">
              <span class="tl-tile-slug">{camera.slug}</span>
              <label class="tl-tile-toggle" title="Include this camera in scrubbing/playback">
                <input type="checkbox" data-tl-toggle checked /> enabled
              </label>
            </div>
            <div class="tl-tile-body">
              <img data-tl-thumb alt="" hidden />
              <div class="tl-tile-placeholder" data-tl-placeholder>—</div>
            </div>
            <div class="tl-tile-foot muted text-sm">
              <span data-tl-state>idle</span>
              {purgeBtn}
            </div>
          </div>
        |]
        where
          camIdText = tshow (camera |> get #id)
          -- Admin-only: tombstone this camera's recordings across the
          -- CURRENT timeline window (same verified-purge flow the old
          -- /Archive table used). Hidden inputs carry UTC ISO; the
          -- controller redirects back to /Timeline with the window.
          purgeBtn =
            if isAdmin
              then
                [hsx|
                  <form method="POST" action={purgeAction} class="tl-purge-form"
                        data-confirm={"Purge " <> camera.slug <> " recordings in the current window?"}>
                    <input type="hidden" name="purgeFrom" value={iso winFrom} />
                    <input type="hidden" name="purgeTo" value={iso winTo} />
                    <button type="submit" class="link-button tl-purge-btn" title="Purge recordings in window">purge</button>
                  </form>
                |]
              else mempty
          purgeAction = "/PurgeRecording?purgeCameraId=" <> camIdText
