{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Layout (renderLayout) where

import Generated.Types
import Hnvr.Web.Auth ()
import IHP.ViewPrelude

-- | Default application layout. Wraps each page with nav + main container.
-- Stylesheet is served from /static/app.css (compiled by hnvr-static from
-- static/src.css via the tailwind standalone CLI).
renderLayout inner =
  [hsx|
<html lang="en">
  <head>
    <title>HNVR</title>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no" />
    <meta name="theme-color" content="#09090b" />
    <link rel="stylesheet" href="/static/app.css" />
    <link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Crect width='16' height='16' fill='%2309090b'/%3E%3Ccircle cx='8' cy='8' r='3' fill='%2338bdf8'/%3E%3C/svg%3E" />
  </head>
  <body>
    <div class="shell">
      <nav class="topnav">
        <a href="/" class="brand">
          <span class="dot"></span>
          HNVR
        </a>
        <a href="/" class="nav-link">Dashboard</a>
        <a href="/Cameras" class="nav-link">Cameras</a>
        <a href="/Archive" class="nav-link">Archive</a>
        <a href="/Hosts" class="nav-link">Hosts</a>
        <span class="spacer"></span>
        {userPill}
      </nav>
      <main class="main">{inner}</main>
    </div>
  </body>
</html>
|]
  where
    userPill = case (currentUserOrNothing :: Maybe User) of
      Just u ->
        [hsx|
          <span class="user-pill">
            <span class="led led-on"></span>
            <span>{u.email}</span>
            <span>·</span>
            <a href="/DeleteSession">logout</a>
          </span>
        |]
      Nothing ->
        [hsx|
          <a href="/NewSession" class="nav-link">
            <span class="led led-off"></span>
            Login
          </a>
        |]
