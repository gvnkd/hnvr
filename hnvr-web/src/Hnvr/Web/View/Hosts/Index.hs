{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Hosts.Index (IndexView (..)) where

import Data.Coerce (coerce)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import Generated.Types
import Hnvr.Web.CameraStatus (hostDisplayLive)
import Hnvr.Web.View.Layout (renderLayout)
import Hnvr.Web.View.Time (tzTime)
import IHP.ViewPrelude

data IndexView = IndexView
  { hosts :: [Host],
    cameras :: [Camera],
    now :: UTCTime
  }

instance View IndexView where
  html IndexView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Hosts</h1>
          <div class="subtitle">{nLive} of {nHosts} live · leader + workers</div>
        </div>
      </div>
      {forEach hosts (renderHost cameras)}
    |]
    where
      nHosts = tshow (length hosts) :: Text
      nLive = tshow (length (filter (\h -> hostDisplayLive now h.lastHealthAt) hosts)) :: Text

      renderHost cams h =
        [hsx|
          <div class="card mb-4">
            <div class="card-header">
              <span class="flex items-center gap-2">
                {ledFor h.lastHealthAt}
                <span class="font-mono t-strong">{h.id}</span>
                {roleBadge h.isLeader}
                {connBadge h.lastHealthAt}
              </span>
              <span class="muted">{lastHealthHtml h.lastHealthAt}</span>
            </div>
            <table class="table">
              <tbody>
                {kvRow "GPU" (fromMaybe "—" h.gpuModel)}
                {kvRow "Exec providers" (T.intercalate ", " h.execProviders)}
                <tr class="kv"><th>Last health</th><td>{lastHealthHtml h.lastHealthAt}</td></tr>
              </tbody>
            </table>
            <div class="card-body">
              <div class="section-h mt-0" style="margin-top:0">Cameras assigned</div>
              {renderAssigned cams (coerce h.id :: Text)}
            </div>
          </div>
        |]
        where
          ledFor mh
            | hostDisplayLive now mh = [hsx|<span class="led led-on" title="reporting"></span>|]
            | otherwise = [hsx|<span class="led led-off" title="disconnected — last health >5 min ago"></span>|]
          connBadge mh
            | hostDisplayLive now mh = mempty
            | otherwise = [hsx|<span class="badge badge-danger">DISCONNECTED</span>|]
          roleBadge True = [hsx|<span class="badge badge-info">LEADER</span>|]
          roleBadge False = [hsx|<span class="badge badge-mute">WORKER</span>|]
          lastHealthHtml Nothing = [hsx|—|]
          lastHealthHtml (Just t) = tzTime t
          kvRow k v =
            [hsx|
              <tr class="kv">
                <th>{k}</th>
                <td>{v}</td>
              </tr>
            |]

      renderAssigned cams hostId =
        let ours = filter (\c -> c.assignedHost == Just hostId) cams
         in if null ours
              then [hsx|<div class="empty" style="padding:1rem">No cameras assigned.</div>|]
              else
                [hsx|
                  <ul class="stack-list">
                    {forEach ours renderCamLi}
                  </ul>
                |]
      renderCamLi c = [hsx|<li><span>{c.slug}</span></li>|]
