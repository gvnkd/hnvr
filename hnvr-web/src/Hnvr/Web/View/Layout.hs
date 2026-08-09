{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeFamilies #-}

module Hnvr.Web.View.Layout (renderLayout) where

import IHP.ViewPrelude

-- | Default application layout. Wraps each page with nav + main container.
renderLayout inner = [hsx|
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
    </nav>
    <main>{inner}</main>
  </body>
</html>
|]

css :: Text
css =
  "body { margin:0; font-family:system-ui,sans-serif; color:#222; background:#fafafa; }\
  \.topnav { display:flex; gap:1rem; align-items:center; padding:.75rem 1rem; background:#1f2937; color:#fff; }\
  \.topnav a { color:#fff; text-decoration:none; }\
  \.topnav a.brand { font-weight:bold; font-size:1.2rem; margin-right:1rem; }\
  \main { max-width:1100px; margin:2rem auto; padding:0 1rem; }\
  \.header { display:flex; justify-content:space-between; align-items:center; margin-bottom:1rem; }\
  \table { width:100%; border-collapse:collapse; background:#fff; box-shadow:0 1px 3px rgba(0,0,0,0.08); }\
  \th,td { padding:.6rem .8rem; border-bottom:1px solid #eee; text-align:left; }\
  \th { background:#f3f4f6; font-size:.9rem; text-transform:uppercase; letter-spacing:.03em; }\
  \tr:hover td { background:#f9fafb; }\
  \a.btn, button.btn { display:inline-block; padding:.4rem .8rem; background:#2563eb; color:#fff; border:none; border-radius:4px; text-decoration:none; cursor:pointer; font-size:.9rem; }\
  \form.stacked label { display:block; margin:.6rem 0 .15rem; font-weight:500; font-size:.9rem; }\
  \form.stacked input, form.stacked select, form.stacked textarea { display:block; width:100%; padding:.4rem .6rem; border:1px solid #d1d5db; border-radius:4px; font-size:.95rem; box-sizing:border-box; }\
  \.field-row { margin-bottom:.8rem; }"
