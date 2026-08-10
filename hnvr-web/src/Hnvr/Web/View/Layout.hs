{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

module Hnvr.Web.View.Layout (renderLayout) where

import Generated.Types
import Hnvr.Web.Auth ()
import IHP.ViewPrelude

-- | Default application layout. Wraps each page with nav + main container.
renderLayout inner =
  [hsx|
<html>
  <head>
    <title>HNVR</title>
    <meta http-equiv="Content-Type" content="text/html; charset=utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no" />
    <style>{preEscapedTextValue css}</style>
  </head>
  <body>
    <nav class="topnav">
      <a href="/" class="brand">HNVR</a>
      <a href="/cameras">Cameras</a>
      <a href="/hosts">Hosts</a>
      <span class="nav-spacer"></span>
      {userLink}
    </nav>
    <main>{inner}</main>
  </body>
</html>
|]
  where
    userLink = case (currentUserOrNothing :: Maybe User) of
      Just _ -> [hsx|<a class="nav-user" href="/DeleteSession">Logout</a>|]
      Nothing -> [hsx|<a class="nav-user" href="/NewSession">Login</a>|]

css :: Text
css =
  "body { margin:0; font-family:system-ui,sans-serif; color:#222; background:#fafafa; }\
  \.topnav { display:flex; gap:1rem; align-items:center; padding:.75rem 1rem; background:#1f2937; color:#fff; }\
  \.topnav a { color:#fff; text-decoration:none; }\
  \.topnav a.brand { font-weight:bold; font-size:1.2rem; margin-right:1rem; }\
  \.topnav .nav-spacer { flex:1; }\
  \.topnav .nav-user { font-size:.85rem; opacity:.85; }\
  \main { max-width:1100px; margin:2rem auto; padding:0 1rem; }\
  \.header { display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem; }\
  \table { width:100%; border-collapse:collapse; background:#fff; box-shadow:0 1px 3px rgba(0,0,0,0.08); }\
  \th,td { padding:.6rem .8rem; border-bottom:1px solid #eee; text-align:left; }\
  \th { background:#f3f4f6; font-size:.9rem; text-transform:uppercase; letter-spacing:.03em; }\
  \tr:hover td { background:#f9fafb; }\
  \a.btn, button.btn { display:inline-block; padding:.4rem .8rem; background:#2563eb; color:#fff; border:none; border-radius:4px; text-decoration:none; cursor:pointer; font-size:.9rem; }\
  \form.stacked label { display:block; margin:.6rem 0 .15rem; font-weight:500; font-size:.9rem; }\
  \form.stacked input, form.stacked select, form.stacked textarea { display:block; width:100%; padding:.4rem .6rem; border:1px solid #d1d5db; border-radius:4px; font-size:.95rem; box-sizing:border-box; }\
  \.field-row { margin-bottom:.8rem; }\
  \.grid { display:grid; grid-template-columns:repeat(auto-fill, minmax(240px, 1fr)); gap:1rem; }\
  \.card { background:#fff; border-radius:6px; box-shadow:0 1px 3px rgba(0,0,0,0.08); overflow:hidden; }\
  \.card .thumb { display:flex; align-items:center; justify-content:center; height:140px; background:#111; color:#fff; font-size:2rem; text-decoration:none; }\
  \.card .thumb:hover { background:#1f2937; }\
  \.card .card-body { padding:.6rem .8rem; }\
  \.card .meta { color:#6b7280; font-size:.85rem; margin:.15rem 0 .5rem; }"
