{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Central timestamp rendering: emits UTC with a @data-utc-ts@
-- attribute; /static/app.js rewrites the text client-side into the
-- viewer's timezone (profile setting, browser-local fallback). Views
-- must not format timestamps ad-hoc anymore — use 'tzTime' /
-- 'tzTimeOfDay' so every rendered time follows the profile timezone.
module Hnvr.Web.View.Time
  ( tzTime,
    tzTimeOfDay,
  )
where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import IHP.ViewPrelude

-- | Full date-time, shown as "YYYY-MM-DD HH:MM:SS" (localized by JS).
tzTime :: UTCTime -> Html
tzTime t = [hsx|<span class="utc-ts" data-utc-ts={isoAttr t}>{fmtDateTime t}</span>|]

-- | Time-of-day only ("HH:MM:SS"), e.g. the live event feed.
tzTimeOfDay :: UTCTime -> Html
tzTimeOfDay t = [hsx|<span class="utc-ts" data-utc-ts={isoAttr t} data-utc-ts-fmt="time">{fmtClock t}</span>|]

isoAttr :: UTCTime -> Text
isoAttr = T.pack . iso8601Show

fmtDateTime :: UTCTime -> Text
fmtDateTime = T.pack . formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S"

fmtClock :: UTCTime -> Text
fmtClock = T.pack . formatTime defaultTimeLocale "%H:%M:%S"
