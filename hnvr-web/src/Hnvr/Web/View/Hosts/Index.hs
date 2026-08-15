{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Hosts.Index (IndexView (..)) where

import Data.Coerce (coerce)
import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude

data IndexView = IndexView
  { hosts :: [Host],
    cameras :: [Camera]
  }

instance View IndexView where
  html IndexView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Hosts</h1>
          <div class="subtitle">{nHosts} reporting · leader + workers</div>
        </div>
      </div>
      {forEach hosts (renderHost cameras)}
    |]
    where
      nHosts = tshow (length hosts) :: Text

      renderHost cams h =
        [hsx|
          <div class="card mb-4">
            <div class="card-header">
              <span class="flex items-center gap-2">
                {ledFor h.lastHealthAt}
                <span class="font-mono t-strong">{h.id}</span>
                {roleBadge h.isLeader}
              </span>
              <span class="muted">{fromMaybe "—" (fmap tshow h.lastHealthAt)}</span>
            </div>
            <table class="table">
              <tbody>
                {kvRow "GPU" (fromMaybe "—" h.gpuModel)}
                {kvRow "Exec providers" (tshow h.execProviders)}
                {kvRow "Last health" (fromMaybe "—" (fmap tshow h.lastHealthAt))}
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
            | Just _ <- mh = [hsx|<span class="led led-on"></span>|]
            | otherwise = [hsx|<span class="led led-off"></span>|]
          roleBadge True = [hsx|<span class="badge badge-info">LEADER</span>|]
          roleBadge False = [hsx|<span class="badge badge-mute">WORKER</span>|]
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
      renderCamLi c = [hsx|<li><span>{c.slug}</span><a href={showCam c}>config →</a></li>|]
      showCam c = "/ShowCamera?cameraId=" <> tshow (c |> get #id)
