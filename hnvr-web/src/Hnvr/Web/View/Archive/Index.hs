{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Archive browser view: filter form + paginated recordings table.
module Hnvr.Web.View.Archive.Index
  ( IndexView (..),
    RecordingRow (..),
  )
where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, diffUTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Data.Word (Word64)
import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude

-- | One row of the recordings table, pre-aggregated by the controller
-- from 'Hnvr.Core.Recording.Recording'.
data RecordingRow = RecordingRow
  { rrCameraId :: Text,
    rrCameraSlug :: Text,
    rrStart :: UTCTime,
    rrEnd :: UTCTime,
    rrSegments :: Int,
    rrBytes :: Word64,
    rrHasAudio :: Bool,
    rrGapCount :: Int,
    -- | Distinct capturing hosts across the group's segments.
    rrHosts :: [Text],
    -- | sha256 of the group's first segment (integrity cross-check).
    rrFirstSha :: Text
  }

data IndexView = IndexView
  { cameras :: [Camera],
    rows :: [RecordingRow],
    fltCamera :: Maybe Text,
    fltFrom :: Maybe Text,
    fltTo :: Maybe Text,
    fltQ :: Maybe Text,
    fltMinDur :: Maybe Int,
    page :: Int,
    totalPages :: Int,
    total :: Int,
    notice :: Maybe Text,
    isAdmin :: Bool,
    queryString :: Text
  }

instance View IndexView where
  html IndexView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Archive</h1>
          <div class="subtitle">{total} recording(s) · segments grouped with 30s gap tolerance · click a row to play</div>
        </div>
      </div>

      {noticeHtml}

      <div class="card collapsible is-open" data-collapsible="1" data-collapse-id="archive-filters">
        <button class="collapse-trigger" data-collapse-trigger="1" aria-expanded="true" type="button">
          <span>Filters</span>
          <span class="chevron">▾</span>
        </button>
        <div class="collapse-body"><div>
        <form class="form p-4" method="GET" action="/Archive">
          <div class="field">
            <label>Camera</label>
            <select name="cameraId">
              <option value="">All cameras</option>
              {forEach cameras cameraOption}
            </select>
          </div>
          <div class="field">
            <label>From (UTC)</label>
            <input type="datetime-local" name="from" value={fromMaybe "" fltFrom} />
          </div>
          <div class="field">
            <label>To (UTC)</label>
            <input type="datetime-local" name="to" value={fromMaybe "" fltTo} />
          </div>
          <div class="field">
            <label>Min duration (s)</label>
            <input type="number" name="minDuration" min="0" value={minDurValue} />
          </div>
          <div class="field">
            <label>Search slug</label>
            <input type="text" name="q" placeholder="cam-197" value={fromMaybe "" fltQ} />
          </div>
          <div class="field">
            <button type="submit" class="btn btn-primary">Filter</button>
            <a class="btn btn-ghost" href="/Archive">Reset</a>
          </div>
        </form>
        </div></div>
      </div>

      {renderRows rows}
      {pagination}
    |]
    where
      minDurValue = maybe "" tshow fltMinDur :: Text

      noticeHtml = case notice of
        Just n -> [hsx|<div class="card"><span class="badge badge-warn">{n}</span></div>|]
        Nothing -> [hsx||]

      cameraOption c =
        [hsx|
          <option value={cid} selected={isSelected}>{c.slug}</option>
        |]
        where
          cid = tshow (c |> get #id)
          isSelected = fltCamera == Just cid

      renderRows [] =
        [hsx|
          <div class="empty">
            <span class="empty-icon">⌖</span>
            No recordings in this window.
          </div>
        |]
      renderRows rs =
        [hsx|
          <div class="card">
            <div class="card-header">
              <span>recordings</span>
              <input class="table-filter" type="text" placeholder="filter…" data-table-filter="#archive-table" />
            </div>
            <table class="table" id="archive-table" data-sortable="1">
              <thead>
                <tr>
                  <th>Camera</th>
                  <th>Start (UTC)</th>
                  <th>Duration</th>
                  <th>Host</th>
                  <th class="text-right">Size</th>
                  <th class="text-right">Segments</th>
                  <th data-no-sort="1">Flags</th>
                  <th class="text-right" data-no-sort="1">Actions</th>
                </tr>
              </thead>
              <tbody>{forEach rs renderRow}</tbody>
            </table>
          </div>
        |]

      renderRow r =
        [hsx|
          <tr data-href={playUrl}>
            <td class="mono t-strong">{r.rrCameraSlug}</td>
            <td class="mono">{fmtTs (r.rrStart)}</td>
            <td class="mono">{fmtDur (r.rrStart) (r.rrEnd)}</td>
            <td>{hostBadges}</td>
            <td class="mono text-right">{fmtBytes (r.rrBytes)}</td>
            <td class="mono text-right" title={shaTitle}>{tshow (r.rrSegments)}</td>
            <td>
              {audioBadge}
              {gapsBadge}
            </td>
            <td class="text-right whitespace-nowrap">
              <a href={playUrl} class="btn btn-ghost btn-sm">Play</a>
              {deleteForm}
            </td>
          </tr>
        |]
        where
          playUrl =
            "/PlayerArchive?cameraId="
              <> r.rrCameraId
              <> "&from="
              <> iso (r.rrStart)
              <> "&to="
              <> iso (r.rrEnd)
          audioBadge =
            if r.rrHasAudio
              then [hsx|<span class="badge badge-info">audio</span>|]
              else [hsx||]
          -- Distinct capturing hosts for the group (>1 = a failover
          -- happened mid-recording). First segment's sha256 rides as
          -- the Segments cell tooltip for S3 integrity cross-checks.
          hostBadges = case r.rrHosts of
            [] -> [hsx|<span class="muted">—</span>|]
            hs -> forEach hs (\h -> [hsx|<span class="badge badge-mute">{h}</span>|])
          shaTitle = "first segment sha256: " <> r.rrFirstSha
          gapsBadge =
            if r.rrGapCount > 0
              then [hsx|<span class="badge badge-warn">{tshow (r.rrGapCount)} gap(s)</span>|]
              else [hsx||]
          deleteForm =
            if isAdmin
              then
                [hsx|
                  <form method="POST" action={deleteUrl} style="display:inline">
                    <input type="hidden" name="purgeFrom" value={iso (r.rrStart)} />
                    <input type="hidden" name="purgeTo" value={iso (r.rrEnd)} />
                    <button type="submit" class="btn btn-danger btn-sm">Delete</button>
                  </form>
                |]
              else [hsx||]
          -- The action URL carries @purgeCameraId@ (the renamed
          -- AutoRoute field for 'PurgeRecordingAction' — the bare
          -- @cameraId@ name clashed with the filter round-trip and
          -- produced URLs like @?cameraId=X&cameraId=X@) plus any
          -- active filter params via 'queryString' so the controller
          -- can redirect back to the same filtered view. The form
          -- body carries only purgeFrom/purgeTo (the recording
          -- window) under prefixed names to avoid clashing with the
          -- filter's from/to.
          --
          -- We also carry the current page (when > 1) so the redirect
          -- doesn't dump the user back on page 1.
          deleteUrl =
            "/PurgeRecording?purgeCameraId="
              <> r.rrCameraId
              <> queryString
              <> (if page > 1 then "&page=" <> tshow page else "")

      pagination =
        [hsx|
          <div class="card">
            <span class="muted">Page {tshow page} / {tshow totalPages}</span>
            {prevLink}
            {nextLink}
          </div>
        |]
        where
          prevLink =
            if page > 1
              then [hsx|<a class="btn btn-ghost btn-sm" href={prevUrl}>← Prev</a>|]
              else [hsx||]
          nextLink =
            if page < totalPages
              then [hsx|<a class="btn btn-ghost btn-sm" href={nextUrl}>Next →</a>|]
              else [hsx||]
          prevUrl = "/Archive?page=" <> tshow (page - 1) <> queryString
          nextUrl = "/Archive?page=" <> tshow (page + 1) <> queryString

      fmtTs = formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S"
      iso = T.pack . iso8601Show
      fmtDur a b =
        let total = floor (diffUTCTime b a) :: Int
            (h, rest) = total `divMod` 3600
            (m, s) = rest `divMod` 60
         in (if h > 0 then tshow h <> "h " else "")
              <> (if m > 0 || h > 0 then tshow m <> "m " else "")
              <> tshow s
              <> "s"
      fmtBytes n
        | n >= 1_073_741_824 = tshow (n `div` 1_073_741_824) <> "." <> tshow ((n `mod` 1_073_741_824) `div` 107_374_182) <> " GB"
        | n >= 1_048_576 = tshow (n `div` 1_048_576) <> " MB"
        | n >= 1024 = tshow (n `div` 1024) <> " KB"
        | otherwise = tshow n <> " B"
