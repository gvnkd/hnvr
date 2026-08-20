{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Layout (renderLayout) where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Generated.Types
import Hnvr.Web (version)
import Hnvr.Web.Auth ()
import IHP.ViewPrelude
import Network.Wai (rawPathInfo)

-- | Application shell: collapsible sidebar nav + topbar + main.
-- Two themes (midnight/daylight) are switched client-side via
-- /static/app.js; the inline head script applies the persisted theme
-- before first paint to avoid a flash. Stylesheet and app.js are
-- served from /static (compiled by hnvr-static / copied by the NixOS
-- module's preStart).
renderLayout inner =
  [hsx|
<html lang="en" data-theme="midnight">
  <head>
    <title>HNVR</title>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no" />
    <meta name="theme-color" content="#07090d" />
    {themeInitScript}
    <link rel="stylesheet" href="/static/app.css" />
    <script src="/static/app.js"></script>
    <link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Crect width='16' height='16' fill='%2309090b'/%3E%3Ccircle cx='8' cy='8' r='3' fill='%2338bdf8'/%3E%3C/svg%3E" />
  </head>
  <body data-user-tz={userTzAttr}>
    <div class="shell">
      <aside class="sidenav">
        <button class="icon-btn nav-toggle" data-nav-toggle="1" aria-label="Toggle navigation" title="Toggle navigation">☰</button>
        <a href="/" class="brand">
          <span class="dot"></span>
          <span class="wordmark">HNVR</span>
        </a>
        <div class="brand-version"><span class="badge badge-mute">v{version}</span></div>
        <div class="nav-section">Monitor</div>
        {navItem "/" "▦" "Dashboard" (currentPath == "/" || currentPath == "/Dashboard")}
        {navItem "/Events" "◈" "Events" (isPrefix "/Events")}
        {navItem "/Archive" "▤" "Archive" (isPrefix "/Archive" || isPrefix "/PlayerArchive")}
        <div class="nav-section">Configure</div>
        {navItem "/Cameras" "◫" "Cameras" (isPrefix "/Cameras" || isPrefix "/NewCamera" || isPrefix "/EditCamera" || isPrefix "/ShowCamera")}
        {navItem "/Rules" "⌖" "Rules" (isPrefix "/Rules" || isPrefix "/NewRule" || isPrefix "/EditRule")}
        <div class="nav-section">System</div>
        {navItem "/Stats" "▥" "Stats" (isPrefix "/Stats")}
        {navItem "/Hosts" "⬡" "Hosts" (isPrefix "/Hosts")}
        {navItem "/AuditLog" "≣" "Audit" (isPrefix "/AuditLog")}
        <span class="spacer"></span>
        <div class="sidenav-footer">
          {themeMenu}
          {userPill}
          <div class="version-tag">v{version}</div>
        </div>
      </aside>
      <div class="content">
        <header class="topbar">
          <span class="clock"></span>
        </header>
        <main class="main">{renderFlashMessages}{inner}</main>
      </div>
    </div>
  </body>
</html>
|]
  where
    themeInitScript =
      preEscapedTextValue
        ( "<script>try{document.documentElement.setAttribute('data-theme',localStorage.getItem('hnvr-theme')||'midnight')}catch(e){}</script>" ::
            Text
        )
    currentPath = cs (rawPathInfo ?request) :: Text
    isPrefix p = p `T.isPrefixOf` currentPath

    -- Logged-in user's profile timezone (IANA name), empty when unset —
    -- app.js falls back to the browser's zone. Consumed by the topbar
    -- clock and the [data-utc-ts] timestamp rewriting.
    userTzAttr = fromMaybe "" ((currentUserOrNothing :: Maybe User) >>= (.timezone))

    navItem href glyph label active =
      [hsx|
        <a href={href} class={navClass}>
          <span class="nav-icon">{glyph}</span>
          <span class="nav-label">{label}</span>
        </a>
      |]
      where
        navClass = if active then "nav-item active" :: Text else "nav-item"

    themeMenu =
      [hsx|
        <div class="dropdown" data-dropdown="1">
          <button class="dropdown-item" data-dropdown-button="1" aria-expanded="false" title="Switch theme">
            <span>◐</span>
            <span class="sidenav-foot-label">Theme</span>
          </button>
          <div class="dropdown-menu" hidden>
            <button class="dropdown-item" data-theme-option="midnight">◑ Midnight Ops</button>
            <button class="dropdown-item" data-theme-option="daylight">☀ Daylight</button>
          </div>
        </div>
      |]

    userPill = case (currentUserOrNothing :: Maybe User) of
      Just u ->
        [hsx|
          <span class="user-block">
            <span class="led led-on"></span>
            <a href="/ShowProfile" class="sidenav-foot-label" title="Profile settings">{u.email}</a>
            <span class="sidenav-foot-label">·</span>
            <form method="POST" action="/DeleteSession" style="display:inline">
              <input type="hidden" name="_method" value="DELETE" />
              <button type="submit" class="link-button">logout</button>
            </form>
          </span>
        |]
      Nothing ->
        [hsx|
          <span class="user-block">
            <span class="led led-off"></span>
            <a href="/NewSession">Login</a>
          </span>
        |]
