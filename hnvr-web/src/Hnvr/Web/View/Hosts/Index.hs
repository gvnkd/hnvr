{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Hosts.Index (IndexView (..)) where

import Data.Coerce (coerce)
import Data.List (groupBy, sortBy)
import Data.Maybe (fromMaybe)
import Data.Ord (comparing)
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
      <div class="header">
        <h1>Hosts</h1>
      </div>
      {forEach hosts (renderHost cameras)}
    |]
    where
      renderHost cams h =
        [hsx|
          <h2>{h.id}</h2>
          <table>
            <tr><th>Leader</th><td>{tshow h.isLeader}</td></tr>
            <tr><th>GPU</th><td>{fromMaybe "—" h.gpuModel}</td></tr>
            <tr><th>Exec providers</th><td>{tshow h.execProviders}</td></tr>
            <tr><th>Last health</th><td>{fromMaybe "—" (fmap tshow h.lastHealthAt)}</td></tr>
          </table>
          <h3>Cameras assigned</h3>
          {renderAssigned cams (coerce h.id :: Text)}
        |]
      renderAssigned cams hostId =
        let ours = filter (\c -> c.assignedHost == Just hostId) cams
         in if null ours
              then [hsx|<p>No cameras assigned.</p>|]
              else
                [hsx|
                  <ul>
                    {forEach ours renderCamLi}
                  </ul>
                |]
      renderCamLi c = [hsx|<li>{c.slug} · <a href={showCam c}>config</a></li>|]
      showCam c = "/cameras/" <> tshow c.id
