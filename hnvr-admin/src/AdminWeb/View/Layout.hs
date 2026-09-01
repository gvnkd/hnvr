{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | hnvr-admin shell: minimal sidebar reusing the end-user app's CSS
-- (same /static/app.css), own nav. Deliberately no PTZ/timeline/JS
-- machinery — app.js is loaded for tables/tz only.
module AdminWeb.View.Layout (renderAdminLayout) where

import AdminWeb.BasePath (urlFor)
import Data.Text (Text)
import qualified Data.Text as T
import Generated.Types
import Hnvr.Web (version)
import Hnvr.Web.Auth ()
import IHP.ViewPrelude
import Network.Wai (rawPathInfo)

renderAdminLayout inner =
  [hsx|
<html lang="en" data-theme="midnight">
  <head>
    <title>HNVR admin</title>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no" />
    <meta name="theme-color" content="#07090d" />
    <link rel="stylesheet" href={urlFor "/static/app.css"} />
    <script src={urlFor "/static/app.js"}></script>
  </head>
  <body>
    <div class="shell">
      <aside class="sidenav">
        <button class="icon-btn nav-toggle" data-nav-toggle="1" aria-label="Toggle navigation" title="Toggle navigation">☰</button>
        <a href={urlFor "/"} class="brand">
          <span class="dot"></span>
          <span class="wordmark">HNVR <span class="badge badge-warn">admin</span></span>
        </a>
        <div class="brand-version"><span class="badge badge-mute">v{version}</span></div>
        <div class="nav-section">Manage</div>
        {navItem "/" "▦" "Overview" (currentPath == "/" || currentPath == "/Overview")}
        {navItem "/Roles" "⚿" "Roles" (isPrefix "/Roles" || isPrefix "/NewRole" || isPrefix "/EditRole")}
        {navItem "/Users" "◍" "Users" (isPrefix "/Users" || isPrefix "/NewUser" || isPrefix "/EditUser")}
        <div class="nav-section">Topology</div>
        {navItem "/Cameras" "◫" "Cameras" (isPrefix "/Cameras" || isPrefix "/NewCamera" || isPrefix "/EditCamera" || isPrefix "/ShowCamera")}
        {navItem "/Rules" "⌖" "Rules" (isPrefix "/Rules" || isPrefix "/NewRule" || isPrefix "/EditRule")}
        <span class="spacer"></span>
        <div class="sidenav-footer">
          {userPill}
          <div class="version-tag">v{version}</div>
        </div>
      </aside>
      <div class="content">
        <header class="topbar"><span class="clock"></span></header>
        <main class="main">{renderFlashMessages}{inner}</main>
      </div>
    </div>
  </body>
</html>
|]
  where
    currentPath = cs (rawPathInfo ?request) :: Text
    isPrefix p = p `T.isPrefixOf` currentPath

    navItem href glyph label active =
      [hsx|
        <a href={urlFor href} class={navClass}>
          <span class="nav-icon">{glyph}</span>
          <span class="nav-label">{label}</span>
        </a>
      |]
      where
        navClass = if active then "nav-item active" :: Text else "nav-item"

    userPill = case (currentUserOrNothing :: Maybe User) of
      Just u ->
        [hsx|
          <span class="user-block">
            <span class="led led-on"></span>
            <span class="sidenav-foot-label">{u.email}</span>
            <span class="sidenav-foot-label">·</span>
            <form method="POST" action={urlFor "/DeleteSession"} style="display:inline">
              <input type="hidden" name="_method" value="DELETE" />
              <button type="submit" class="link-button">logout</button>
            </form>
          </span>
        |]
      Nothing -> [hsx|<span class="user-block"><span class="led led-off"></span><a href={urlFor "/NewSession"}>Login</a></span>|]
