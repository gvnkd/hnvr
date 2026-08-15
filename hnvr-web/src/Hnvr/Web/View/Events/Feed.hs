{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Live-feed fragment: the last N events for one camera as a bare
-- list (no layout) — polled by the /live page every 5 s.
module Hnvr.Web.View.Events.Feed
  ( FeedView (..),
  )
where

import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Data.Time.Format (defaultTimeLocale, formatTime)
import Hnvr.Cv.Decode (cocoClassName)
import Hnvr.Web.View.Events.Index (EventRow (..))
import IHP.ViewPrelude

newtype FeedView = FeedView
  { events :: [EventRow]
  }

instance View FeedView where
  html FeedView {..} =
    [hsx|
    <div class="event-feed">
      {forEach events renderEvent}
      {emptyNote}
    </div>
  |]
    where
      emptyNote =
        if null events
          then [hsx|<div class="text-sm muted">no events yet</div>|]
          else [hsx||]
      renderEvent ev =
        [hsx|
        <div class="event-feed-row">
          <span class="mono text-sm">{fmt ev.erTs}</span>
          {badge ev.erKind}
          <span class="text-sm">{cls}</span>
          <span class="text-sm muted">{conf}</span>
        </div>
      |]
        where
          cls = maybe "—" cocoClassName ev.erClassId
          conf = maybe "" (\c -> tshow (round (c * 100) :: Int) <> "%") ev.erConfidence
      fmt = T.pack . formatTime defaultTimeLocale "%H:%M:%S"
      badge k
        | k == "line_crossed" = [hsx|<span class="badge badge-warn">line</span>|]
        | k == "zone_enter" = [hsx|<span class="badge badge-info">enter</span>|]
        | k == "zone_exit" = [hsx|<span class="badge badge-info">exit</span>|]
        | k == "zone_inside" = [hsx|<span class="badge badge-mute">inside</span>|]
        | k == "zone_motion" = [hsx|<span class="badge badge-warn">motion</span>|]
        | otherwise = [hsx|<span class="badge badge-mute">{k}</span>|]
