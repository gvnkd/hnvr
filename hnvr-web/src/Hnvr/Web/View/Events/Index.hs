{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /Events view: collapsible filter panel + sortable event table with
-- animated (Ken Burns) bbox thumbnails, a click-to-zoom lightbox, and
-- rows that deep-link into the archive player (Phase 4 + UI v2).
module Hnvr.Web.View.Events.Index
  ( IndexView (..),
    EventRow (..),
  )
where

import Data.Maybe (catMaybes, fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, addUTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.UUID (UUID)
import Generated.Types
import Hnvr.Cv.Decode (cocoClassName)
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude

-- | One event row joined with its camera slug + rule name (built by
-- the controller's SQL; the same split as Archive's RecordingRow).
data EventRow = EventRow
  { erId :: UUID,
    erTs :: UTCTime,
    erKind :: Text,
    erClassId :: Maybe Int,
    erTrackId :: Maybe Int,
    erConfidence :: Maybe Double,
    erThumbnailKey :: Maybe Text,
    erCameraSlug :: Text,
    erCameraUuid :: UUID,
    erRuleName :: Maybe Text,
    -- | Live event clip covering this event, if one exists
    -- (separated event video store).
    erClipId :: Maybe UUID
  }

data IndexView = IndexView
  { events :: [(EventRow, Maybe Text)],
    cameras :: [Camera],
    fltCamera :: Maybe Text,
    fltKind :: Maybe Text,
    fltFrom :: Maybe Text,
    fltTo :: Maybe Text,
    page :: Int,
    hasNext :: Bool
  }

instance View IndexView where
  html IndexView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Events</h1>
          <div class="subtitle">line crossing + zone intrusion · click a row to replay</div>
        </div>
      </div>

      <div class="card collapsible is-open" data-collapsible="1" data-collapse-id="events-filters">
        <button class="collapse-trigger" data-collapse-trigger="1" aria-expanded="true">
          <span>Filters</span>
          <span class="chevron">▾</span>
        </button>
        <div class="collapse-body"><div>
          <form class="form p-4" method="GET" action="/Events">
            <div class="field">
              <label for="cameraId">Camera</label>
              <select class="input" id="cameraId" name="cameraId">
                <option value="">all</option>
                {forEach cameras cameraOption}
              </select>
            </div>
            <div class="field">
              <label for="kind">Kind</label>
              <select class="input" id="kind" name="kind">
                {forEach kinds kindOption}
              </select>
            </div>
            <div class="field">
              <label for="from">From</label>
              <input class="input" id="from" name="from" type="datetime-local" value={fromMaybe "" fltFrom} />
            </div>
            <div class="field">
              <label for="to">To</label>
              <input class="input" id="to" name="to" type="datetime-local" value={fromMaybe "" fltTo} />
            </div>
            <button class="btn btn-primary" type="submit">Filter</button>
          </form>
        </div></div>
      </div>

      <div class="card mt-4">
        <div class="card-header">
          <span>page {tshow page}</span>
          <input class="table-filter" type="text" placeholder="filter rows…" data-table-filter="#events-table" />
        </div>
        <table class="table" id="events-table" data-sortable="1">
          <thead>
            <tr>
              <th data-no-sort="1"></th>
              <th>Time (UTC)</th>
              <th>Camera</th>
              <th>Kind</th>
              <th>Class</th>
              <th>Conf</th>
              <th>Track</th>
              <th>Rule</th>
              <th data-no-sort="1"></th>
            </tr>
          </thead>
          <tbody>
            {forEach events renderEvent}
          </tbody>
        </table>
        <div class="card-body">
          {pagination}
        </div>
      </div>

      <div id="lightbox" class="lightbox" hidden>
        <figure>
          <img alt="event frame" />
          <figcaption></figcaption>
        </figure>
      </div>
    |]
    where
      kinds =
        [ ("", "all"),
          ("line_crossed", "line crossed"),
          ("zone_enter", "zone enter"),
          ("zone_exit", "zone exit"),
          ("zone_inside", "zone inside"),
          ("zone_motion", "zone motion")
        ]

      cameraOption cam =
        [hsx|<option value={camUuid} selected={isSelected}>{cam.slug}</option>|]
        where
          camUuid = tshow (cam |> get #id)
          isSelected = fltCamera == Just camUuid

      kindOption (value, label) =
        [hsx|<option value={value} selected={fltKind == Just value}>{label}</option>|]

      renderEvent (ev, mThumbUrl) =
        [hsx|
        <tr data-href={playUrl ev}>
          <td>{thumb ev mThumbUrl}</td>
          <td class="mono">{fmtTs ev.erTs}</td>
          <td class="mono">{ev.erCameraSlug}</td>
          <td>{kindBadge ev.erKind}</td>
          <td>{className}</td>
          <td>{confText}</td>
          <td class="mono">{trackText}</td>
          <td>{fromMaybe "—" ev.erRuleName}</td>
          <td>{clipCell ev}</td>
        </tr>
      |]
        where
          className = maybe "—" cocoClassName ev.erClassId
          confText = maybe "—" (\c -> tshow (round (c * 100) :: Int) <> "%") ev.erConfidence
          trackText = maybe "—" tshow ev.erTrackId

      -- Clip play button when the event is covered by an event clip,
      -- plus the classic archive deep-link (30 s window).
      clipCell ev =
        [hsx|
          <span class="row-actions">
            {clipBtn}
            <a class="btn btn-ghost btn-sm" href={playUrl ev}>archive</a>
          </span>
        |]
        where
          clipBtn = case ev.erClipId of
            Just cid ->
              [hsx|<a class="btn btn-primary btn-sm" href={clipUrl}>▶ clip</a>|]
              where
                clipUrl = "/PlayerEventClip?clipId=" <> tshow cid
            Nothing -> [hsx||]

      thumb ev mThumbUrl = case mThumbUrl of
        Just url ->
          [hsx|
            <span class="ev-thumb" data-full={url} data-caption={caption}>
              <img src={url} alt="event thumbnail" />
            </span>
          |]
          where
            caption = ev.erCameraSlug <> " · " <> fmtTs ev.erTs <> " UTC"
        Nothing -> [hsx|<span class="badge badge-mute">no image</span>|]

      kindBadge k
        | k == "line_crossed" = [hsx|<span class="badge badge-warn">line crossed</span>|]
        | k == "zone_enter" = [hsx|<span class="badge badge-info">zone enter</span>|]
        | k == "zone_exit" = [hsx|<span class="badge badge-info">zone exit</span>|]
        | k == "zone_inside" = [hsx|<span class="badge badge-mute">zone inside</span>|]
        | k == "zone_motion" = [hsx|<span class="badge badge-warn">zone motion</span>|]
        | otherwise = [hsx|<span class="badge badge-mute">{k}</span>|]

      -- Deep-link into the archive player: 30 s window either side of
      -- the event, seek target = the event ts (parseWhen-compatible).
      playUrl ev =
        let (from, to, t) = (addUTCTime (-30) ev.erTs, addUTCTime 30 ev.erTs, ev.erTs)
            fmt = T.pack . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S"
         in "/PlayerArchive?cameraId="
              <> tshow ev.erCameraUuid
              <> "&from="
              <> fmt from
              <> "&to="
              <> fmt to
              <> "&t="
              <> fmt t

      fmtTs = T.pack . formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S"

      pagination =
        [hsx|
        <span class="text-sm muted">page {tshow page}</span>
        {prevLink} {nextLink}
      |]
      prevLink
        | page > 1 = [hsx|<a class="btn btn-ghost" href={pageUrl (page - 1)}>← Prev</a>|]
        | otherwise = [hsx||]
      nextLink
        | hasNext = [hsx|<a class="btn btn-ghost" href={pageUrl (page + 1)}>Next →</a>|]
        | otherwise = [hsx||]
      pageUrl p = "/Events?" <> filterQuery <> "page=" <> tshow p
      filterQuery =
        T.intercalate "&" (catMaybes [qp "cameraId" fltCamera, qp "kind" fltKind, qp "from" fltFrom, qp "to" fltTo])
      qp name = fmap (\v -> name <> "=" <> v)
