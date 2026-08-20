{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /ShowProfile — the logged-in user's own settings: timezone used to
-- display times across the web UI (IANA name; empty = browser-local).
-- The dropdown is populated client-side from
-- @Intl.supportedValuesOf("timeZone")@; a button fills it from the
-- browser's detected zone.
module Hnvr.Web.View.Profile.Show
  ( ShowView (..),
  )
where

import Data.Maybe (fromMaybe)
import Generated.Types
import Hnvr.Web.View.Layout (renderLayout)
import IHP.ViewPrelude

newtype ShowView = ShowView
  { user :: User
  }

instance View ShowView where
  html ShowView {..} =
    renderLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>Profile</h1>
          <div class="subtitle">{user.email}</div>
        </div>
      </div>

      <div class="card">
        <form class="form p-4" method="POST" action="/UpdateProfile">
          <div class="field">
            <label for="timezone">Timezone</label>
            <select class="input" id="timezone" name="timezone" data-tz-select="1">
              <option value="">Browser default (<span data-tz-browser="1">detecting…</span>)</option>
              {savedOption}
            </select>
            <div class="text-sm muted">
              Times across the web UI are shown in this zone. Saved:
              <span class="mono">{savedLabel}</span>
            </div>
          </div>
          <div class="field">
            <button class="btn btn-primary" type="submit">Save</button>
            <button class="btn btn-ghost" type="button" data-tz-use-browser="1">Use browser timezone</button>
          </div>
        </form>
      </div>
    |]
    where
      savedLabel = fromMaybe "browser default" user.timezone
      savedOption = case user.timezone of
        Nothing -> [hsx||]
        Just tz -> [hsx|<option value={tz} selected>{tz}</option>|]
