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
import Hnvr.Web.BasePath (urlFor)
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
        <form class="form p-4" method="POST" action={urlFor "/UpdateProfile"}>
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
            <label for="locale">Date &amp; time format (locale)</label>
            <input class="input" id="locale" name="locale" list="locale-suggestions" value={fromMaybe "" user.locale} placeholder="browser default" />
            <datalist id="locale-suggestions">
              <option value="en-US">en-US — 08/31/2026, 2:30 PM</option>
              <option value="en-GB">en-GB — 31/08/2026, 14:30</option>
              <option value="ru-RU">ru-RU — 31.08.2026, 14:30</option>
              <option value="de-DE">de-DE — 31.08.2026, 14:30</option>
              <option value="sv-SE">sv-SE — 2026-08-31 14:30 (ISO)</option>
              <option value="ja-JP">ja-JP — 2026/08/31 14:30</option>
            </datalist>
            <div class="text-sm muted">
              BCP 47 tag for rendering dates/times (e.g. en-GB, ru-RU, sv-SE). Empty = browser locale.
              Saved: <span class="mono">{savedLocaleLabel}</span>
            </div>
          </div>
          <div class="field">
            <button class="btn btn-primary" type="submit">Save</button>
            <button class="btn btn-ghost" type="button" data-tz-use-browser="1">Use browser timezone</button>
          </div>
        </form>
      </div>

      <div class="card mt-4">
        <div class="card-header"><span>Change password</span></div>
        <form class="form p-4" method="POST" action={urlFor "/UpdatePassword"}>
          <div class="field">
            <label for="currentPassword">Current password</label>
            <input class="input" id="currentPassword" name="currentPassword" type="password" autocomplete="current-password" required="1" />
          </div>
          <div class="field">
            <label for="newPassword">New password</label>
            <input class="input" id="newPassword" name="newPassword" type="password" autocomplete="new-password" required="1" />
            <div class="text-sm muted">At least 8 characters.</div>
          </div>
          <div class="field">
            <label for="newPasswordConfirm">Repeat new password</label>
            <input class="input" id="newPasswordConfirm" name="newPasswordConfirm" type="password" autocomplete="new-password" required="1" />
          </div>
          <div class="field">
            <button class="btn btn-primary" type="submit">Change password</button>
          </div>
        </form>
      </div>
    |]
    where
      savedLabel = fromMaybe "browser default" user.timezone
      savedLocaleLabel = fromMaybe "browser default" user.locale
      savedOption = case user.timezone of
        Nothing -> [hsx||]
        Just tz -> [hsx|<option value={tz} selected>{tz}</option>|]
