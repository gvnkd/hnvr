{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /Stats view (Phase 4): storage + event aggregates with share bars.
module Hnvr.Web.View.Stats.Index
  ( IndexView (..),
    Stats (..),
  )
where

import Data.Int (Int64)
import Data.Text (Text)
import qualified Data.Text as T
import Generated.Types ()
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude
import Text.Printf (printf)

newtype IndexView = IndexView
  { stats :: Stats
  }

-- | @stStorageByCam@: @(slug, bytes, segmentCount)@; @stEvents24hByKind@
-- and @stEvents24hByCam@: @(label, count)@, most frequent first.
data Stats = Stats
  { stStorageByCam :: ![(Text, Int64, Int64)],
    stEventsTotal :: !Int64,
    stEvents24h :: !Int64,
    stEvents24hByKind :: ![(Text, Int64)],
    stEvents24hByCam :: ![(Text, Int64)],
    stRulesEnabled :: !Int64
  }

instance View IndexView where
  html IndexView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Statistics</h1>
          <div class="subtitle">storage & events</div>
        </div>
      </div>

      <div class="section-h">Storage</div>
      <div class="stats-grid">
        {statCard (fmtBytes totalBytes) "total used" (tshow totalSegments <> " segments")}
        {statCard (tshow nCamsRecording) "cameras recording" ("of " <> tshow (length stats.stStorageByCam) <> " configured")}
        {statCard (fmtBytes avgPerCam) "avg per camera" ""}
      </div>
      <div class="card mt-4">
        <table class="table">
          <thead>
            <tr>
              <th>Camera</th>
              <th class="w-1/3">Share</th>
              <th>Segments</th>
              <th>Size</th>
            </tr>
          </thead>
          <tbody>{forEach (stats.stStorageByCam) storageRow}</tbody>
        </table>
      </div>

      <div class="section-h">Events</div>
      <div class="stats-grid">
        {statCard (tshow (stats.stEvents24h)) "last 24h" ""}
        {statCard (tshow (stats.stEventsTotal)) "all time" ""}
        {statCard (tshow (stats.stRulesEnabled)) "active rules" ""}
      </div>
      <div class="card mt-4">
        <div class="card-header">by kind · last 24h</div>
        <table class="table">
          <tbody>{forEach (stats.stEvents24hByKind) kindRow}</tbody>
        </table>
      </div>
      <div class="card mt-4">
        <div class="card-header">by camera · last 24h</div>
        <table class="table">
          <tbody>{forEach (stats.stEvents24hByCam) camEventRow}</tbody>
        </table>
      </div>
    |]
    where
      totalBytes = sum [b | (_, b, _) <- stats.stStorageByCam]
      totalSegments = sum [n | (_, _, n) <- stats.stStorageByCam]
      nCamsRecording = length [() | (_, b, _) <- stats.stStorageByCam, b > 0]
      avgPerCam
        | nCamsRecording > 0 = totalBytes `div` fromIntegral nCamsRecording
        | otherwise = 0

      statCard value label sub =
        [hsx|
          <div class="stat-card">
            <div class="stat-value">{value}</div>
            <div class="stat-label">{label}</div>
            {subHtml}
          </div>
        |]
        where
          subHtml = if T.null sub then [hsx||] else [hsx|<div class="stat-sub">{sub}</div>|]

      bar share =
        [hsx|
          <div class="bar">
            <div class="bar-fill" style={fillStyle}></div>
          </div>
        |]
        where
          fillStyle = "width: " <> T.pack (printf "%.1f" (share * 100)) <> "%;"

      storageRow (slug, bytes, nSegs) =
        [hsx|
          <tr>
            <td class="font-mono">{slug}</td>
            <td>{bar (shareOf bytes totalBytes)}</td>
            <td class="mono">{tshow nSegs}</td>
            <td class="mono">{fmtBytes bytes}</td>
          </tr>
        |]

      kindRow (kind, n) =
        [hsx|
          <tr>
            <td>{kindBadge kind}</td>
            <td>{bar (shareOf n (stats.stEvents24h))}</td>
            <td class="mono text-right">{tshow n}</td>
          </tr>
        |]

      camEventRow (slug, n) =
        [hsx|
          <tr>
            <td class="font-mono">{slug}</td>
            <td>{bar (shareOf n (maxCamEvents))}</td>
            <td class="mono text-right">{tshow n}</td>
          </tr>
        |]
      maxCamEvents = maximum (1 : [n | (_, n) <- stats.stEvents24hByCam])

      kindBadge k
        | k == "line_crossed" = [hsx|<span class="badge badge-warn">line crossed</span>|]
        | k == "zone_enter" = [hsx|<span class="badge badge-info">zone enter</span>|]
        | k == "zone_exit" = [hsx|<span class="badge badge-info">zone exit</span>|]
        | k == "zone_inside" = [hsx|<span class="badge badge-mute">zone inside</span>|]
        | k == "zone_motion" = [hsx|<span class="badge badge-warn">zone motion</span>|]
        | otherwise = [hsx|<span class="badge badge-mute">{k}</span>|]

-- | Share of a part in a total, 0..1 (0 when the total is 0).
shareOf :: Int64 -> Int64 -> Double
shareOf _ 0 = 0
shareOf part total = fromIntegral part / fromIntegral total

-- | Human-readable byte count (1 decimal, binary units).
fmtBytes :: Int64 -> Text
fmtBytes n = pick units
  where
    v = fromIntegral n :: Double
    units =
      [ (1099511627776, "TiB", v / 1099511627776),
        (1073741824, "GiB", v / 1073741824),
        (1048576, "MiB", v / 1048576),
        (1024, "KiB", v / 1024)
      ]
    pick ((thr, u, scaled) : rest)
      | n >= thr = T.pack (printf "%.1f" scaled) <> " " <> u
      | otherwise = pick rest
    pick [] = tshow n <> " B"
