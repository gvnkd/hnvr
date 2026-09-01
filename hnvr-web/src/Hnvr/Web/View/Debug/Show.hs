{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Debug view shell: an @\<img\>@ fed by the multipart stream +
-- the current track legend (server-rendered snapshot at page load;
-- the stream itself carries the live overlay). Dev-only.
module Hnvr.Web.View.Debug.Show (ShowView (..)) where

import qualified Data.UUID as UUID
import Generated.Types
import Hnvr.Cv.DebugRender (trackColorCss)
import Hnvr.Cv.Decode (cocoClassName)
import Hnvr.Cv.Tracker.Sort (Track (..), TrackId (..))
import Hnvr.Web.BasePath (urlFor)
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ModelSupport (Id' (Id))
import IHP.ViewPrelude

data ShowView = ShowView
  { camera :: Camera,
    tracks :: [Track]
  }

instance View ShowView where
  html ShowView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>
            <span class="led led-rec"></span>
            Debug · <span class="font-mono">{camera.slug}</span>
          </h1>
          <div class="subtitle">analysis overlay · dev-only</div>
        </div>
        <div class="actions">
        </div>
      </div>

      <div class="video-frame">
        <img src={streamUrl} alt="analysis stream" />
      </div>

      <table class="table">
        <thead>
          <tr><th></th><th>track</th><th>class</th><th>score</th></tr>
        </thead>
        <tbody>
          {forEach tracks renderTrack}
        </tbody>
      </table>
    |]
    where
      streamUrl = urlFor ("/StreamDebugCamera?cameraId=" <> uuidText)
      uuidText = case camera |> get #id of Id uuid -> UUID.toText uuid

      renderTrack t =
        [hsx|
        <tr>
          <td><span class="badge" style={swatchStyle t}>&nbsp;&nbsp;</span></td>
          <td class="font-mono">{trackIdText t}</td>
          <td>{cocoClassName (tClassId t)}</td>
          <td>{percentText (tScore t)}</td>
        </tr>
      |]

      swatchStyle t = "background-color: " <> trackColorCss (tId t)

      trackIdText t = case tId t of TrackId n -> tshow n

      percentText s = tshow (round (s * 100) :: Int) <> "%"
