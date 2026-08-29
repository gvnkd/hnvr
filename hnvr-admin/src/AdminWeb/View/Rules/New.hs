{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /NewRule — rule creation form with the drawing canvas (Phase 4).
-- The form markup + JS live in 'ruleForm' so the Edit view can reuse
-- it with a prefilled rule.
module AdminWeb.View.Rules.New
  ( NewView (..),
    ruleForm,
  )
where

import AdminWeb.View.Layout (renderAdminLayout)
import Data.Aeson (Value (..), encode)
import qualified Data.Aeson.KeyMap as KM
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (fromMaybe, isJust)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Generated.Types
import Hnvr.Cv.Decode (cocoClassName)
import IHP.ViewPrelude

newtype NewView = NewView
  { camera :: Camera
  }

instance View NewView where
  html NewView {..} =
    renderAdminLayout
      [hsx|
      <div class="page-header">
        <div>
          <h1>New rule · <span class="font-mono">{camera.slug}</span></h1>
          <div class="subtitle">draw on the latest analysis frame</div>
        </div>
      </div>
      {ruleForm camera Nothing "/CreateRule"}
    |]

-- | The rule form: text fields + class checkboxes + a canvas over the
-- camera's @/debug-frame/<uuid>@ still. Clicks draw the line (2
-- points) or polygon (N points, Finish closes); geometry is written
-- into the hidden @geometry@ input as normalized-coords JSON on every
-- change. @mRule@ prefills for the Edit view. The signature needs the
-- request implicit params (pitfall #36) + RankNTypes.
ruleForm :: (?context :: Request, ?request :: Request) => Camera -> Maybe Rule -> Text -> Html
ruleForm camera mRule actionUrl =
  [hsx|
  <div class="card">
    <div class="card-body">
      <form class="form" method="POST" action={actionUrl}>
        <input type="hidden" name="camera_id" value={camId} />
        <div class="field">
          <label for="name">Name</label>
          <input class="input" id="name" name="name" value={nameVal} required />
        </div>
        <div class="field">
          <label for="rule-kind">Kind</label>
          <select class="input" id="rule-kind" name="kind">
            <option value="line_cross" selected={kindIs "line_cross"}>line cross</option>
            <option value="zone_enter" selected={kindIs "zone_enter"}>zone enter</option>
            <option value="zone_exit" selected={kindIs "zone_exit"}>zone exit</option>
            <option value="zone_inside" selected={kindIs "zone_inside"}>zone inside</option>
            <option value="zone_motion" selected={kindIs "zone_motion"}>zone motion (moving only)</option>
          </select>
        </div>
        <div class="field" id="motion-field">
          <label for="rule-motion-threshold">Min movement (% of frame)</label>
          <input class="input" id="rule-motion-threshold" type="number" min="0.5" max="50" step="0.5" value={motionVal} />
          <div class="hint">zone motion only: a track must accumulate at least this much movement inside the zone to fire; stationary objects are ignored</div>
        </div>
        <div class="field" id="direction-field">
          <label for="rule-direction">Direction (line only)</label>
          <select class="input" id="rule-direction" name="direction">
            <option value="any" selected={dirIs "any"}>any</option>
            <option value="positive" selected={dirIs "positive"}>positive</option>
            <option value="negative" selected={dirIs "negative"}>negative</option>
          </select>
        </div>
        <div class="field">
          <label>Classes</label>
          {forEach keptClasses classCheckbox}
        </div>
        <div class="field">
          <label for="cooldown_ms">Cooldown (ms)</label>
          <input class="input" id="cooldown_ms" name="cooldown_ms" type="number" min="0" step="500" value={cooldownVal} />
        </div>
        <div class="field">
          <label><input type="checkbox" name="clip_enabled" checked={clipEnabledVal} /> record event clip</label>
          <div class="hint">save a video clip (pre-roll + post-roll around the event) to the event store, kept for its own retention</div>
        </div>
        <div class="field">
          <label for="clip_preroll_sec">Clip pre-roll (s)</label>
          <input class="input" id="clip_preroll_sec" name="clip_preroll_sec" type="number" min="0" max="60" step="1" value={clipPreVal} />
        </div>
        <div class="field">
          <label for="clip_postroll_sec">Clip post-roll (s)</label>
          <input class="input" id="clip_postroll_sec" name="clip_postroll_sec" type="number" min="1" max="300" step="1" value={clipPostVal} />
        </div>
        <div class="field">
          <label for="clip_retention_hours">Clip retention (hours)</label>
          <input class="input" id="clip_retention_hours" name="clip_retention_hours" type="number" min="1" step="1" value={clipRetVal} />
        </div>
        <div class="field">
          <label><input type="checkbox" name="enabled" checked={enabledVal} /> enabled</label>
        </div>
        <div class="field">
          <label>Geometry — click on the frame</label>
          <div>
            <canvas id="rule-canvas" width="960" height="540" style="max-width:100%; border:1px solid var(--border-strong); border-radius: 10px; cursor:crosshair;"></canvas>
          </div>
          <div class="hint">line: 2 clicks · zone: N clicks then "finish polygon" · drag vertices to adjust · direction arrow = line a→b</div>
          <button class="btn" type="button" id="rule-finish">finish polygon</button>
          <button class="btn" type="button" id="rule-clear">clear</button>
        </div>
        <input type="hidden" name="geometry" id="rule-geometry" value={geometryVal} />
        <input type="hidden" name="classes" id="rule-classes" value={classesVal} />
        <button class="btn btn-primary" type="submit">Save rule</button>
      </form>
    </div>
  </div>
  {scriptTag}
|]
  where
    camId = tshow (camera |> get #id)
    nameVal :: Text
    nameVal = maybe "" (.name) mRule
    kindIs k = maybe (k == "line_cross") (\r -> kindText r.kind == k) mRule
    dirIs d = maybe (d == "any") ((== d) . existingDirection) mRule
    cooldownVal :: Text
    cooldownVal = maybe "5000" (tshow . (.cooldownMs)) mRule
    enabledVal = maybe True (.enabled) mRule
    clipEnabledVal = maybe False (isJust . (.clipRetentionHours)) mRule
    clipPreVal :: Text
    clipPreVal = maybe "5" (tshow . (.clipPrerollSec)) mRule
    clipPostVal :: Text
    clipPostVal = maybe "5" (tshow . (.clipPostrollSec)) mRule
    clipRetVal :: Text
    clipRetVal = maybe "168" (\r -> maybe "168" tshow r.clipRetentionHours) mRule
    classesVal :: Text
    classesVal = maybe "0,1,2,3,5,7" (\r -> T.intercalate "," (map tshow r.classes)) mRule
    geometryVal :: Text
    geometryVal = maybe "" (\r -> cs (encode r.geometry)) mRule
    keptClasses = [0, 1, 2, 3, 5, 7]

    classCheckbox cid =
      [hsx|
      <label class="text-sm">
        <input type="checkbox" class="rule-class" value={tshow cid} checked={checked'} />
        {cocoClassName cid}
      </label>
    |]
      where
        checked' = maybe True (\r -> cid `elem` r.classes) mRule

    kindText LineCross = "line_cross"
    kindText RuleKindZoneEnter = "zone_enter"
    kindText RuleKindZoneExit = "zone_exit"
    kindText RuleKindZoneInside = "zone_inside"
    kindText RuleKindZoneMotion = "zone_motion"

    -- Threshold as a percent for the form; stored normalized (0..1)
    -- in the geometry JSON as min_displacement.
    motionVal :: Text
    motionVal = maybe "3" (tshow . (round :: Double -> Int) . (* 100) . existingMotion) mRule

    existingMotion :: Rule -> Double
    existingMotion r = case r.geometry of
      Object o
        | Just (Number n) <- KM.lookup "min_displacement" o -> toRealFloat n
      _ -> 0.03

    -- Direction for an existing line rule comes from its geometry JSON.
    existingDirection r = case r.geometry of
      Object o
        | Just (String d) <- KM.lookup "direction" o -> d
      _ -> "any"
    scriptTag =
      preEscapedTextValue
        ( "<script>"
            <> js
            <> "</script>"
        )

    js =
      T.unlines
        [ "(function(){",
          "var canvas = document.getElementById('rule-canvas');",
          "var ctx = canvas.getContext('2d');",
          "var kindEl = document.getElementById('rule-kind');",
          "var dirField = document.getElementById('direction-field');",
          "var motionField = document.getElementById('motion-field');",
          "var motionEl = document.getElementById('rule-motion-threshold');",
          "var geoEl = document.getElementById('rule-geometry');",
          "var classesEl = document.getElementById('rule-classes');",
          "var img = new Image();",
          "img.onload = function(){",
          "  canvas.height = Math.round(canvas.width * img.height / img.width);",
          "  redraw();",
          "};",
          "img.src = '/debug-frame/" <> camId <> "?t=' + Date.now();",
          "var points = [];",
          "try { var g = JSON.parse(geoEl.value || 'null');",
          "  if (g && g.polygon) points = g.polygon;",
          "  if (g && g.a && g.b) points = [g.a, g.b];",
          "} catch(e) {}",
          "function kind(){ return kindEl.value; }",
          "function isLine(){ return kind() === 'line_cross'; }",
          "function isMotion(){ return kind() === 'zone_motion'; }",
          "function syncVisibility(){ dirField.style.display = isLine() ? '' : 'none'; motionField.style.display = isMotion() ? '' : 'none'; }",
          "function writeGeometry(){",
          "  var dir = document.getElementById('rule-direction').value;",
          "  if (isLine()) {",
          "    geoEl.value = points.length === 2 ? JSON.stringify({a: points[0], b: points[1], direction: dir}) : '';",
          "  } else {",
          "    var g = {polygon: points};",
          "    if (isMotion()) { var thr = parseFloat(motionEl.value) / 100; if (thr > 0) g.min_displacement = thr; }",
          "    geoEl.value = points.length >= 3 ? JSON.stringify(g) : '';",
          "  }",
          "}",
          "function redraw(){",
          "  ctx.clearRect(0,0,canvas.width,canvas.height);",
          "  if (img.complete && img.naturalWidth) ctx.drawImage(img,0,0,canvas.width,canvas.height);",
          "  ctx.strokeStyle = '#ff3838'; ctx.fillStyle = 'rgba(255,56,56,0.25)'; ctx.lineWidth = 2;",
          "  points.forEach(function(p,i){",
          "    ctx.beginPath(); ctx.arc(p[0]*canvas.width, p[1]*canvas.height, 4, 0, 7); ctx.fill();",
          "    if (i===0 && isLine()) { ctx.fillStyle='#fff'; ctx.fillText('a', p[0]*canvas.width+6, p[1]*canvas.height-6); ctx.fillStyle='rgba(255,56,56,0.25)'; }",
          "    if (i===1 && isLine()) { ctx.fillStyle='#fff'; ctx.fillText('b', p[0]*canvas.width+6, p[1]*canvas.height-6); ctx.fillStyle='rgba(255,56,56,0.25)'; }",
          "  });",
          "  if (isLine() && points.length === 2) {",
          "    ctx.beginPath(); ctx.moveTo(points[0][0]*canvas.width, points[0][1]*canvas.height);",
          "    ctx.lineTo(points[1][0]*canvas.width, points[1][1]*canvas.height); ctx.stroke();",
          "    var mx=(points[0][0]+points[1][0])/2*canvas.width, my=(points[0][1]+points[1][1])/2*canvas.height;",
          "    var dx=points[1][0]-points[0][0], dy=points[1][1]-points[0][1]; var len=Math.sqrt(dx*dx+dy*dy)||1;",
          "    ctx.beginPath(); ctx.moveTo(mx,my);",
          "    ctx.lineTo(mx+(-dy/len)*10-(dx/len)*8, my+(dx/len)*10-(dy/len)*8);",
          "    ctx.lineTo(mx-(-dy/len)*10-(dx/len)*8, my-(dx/len)*10-(dy/len)*8); ctx.stroke();",
          "  }",
          "  if (!isLine() && points.length >= 2) {",
          "    ctx.beginPath(); ctx.moveTo(points[0][0]*canvas.width, points[0][1]*canvas.height);",
          "    for (var i=1;i<points.length;i++) ctx.lineTo(points[i][0]*canvas.width, points[i][1]*canvas.height);",
          "    if (points.length >= 3) ctx.closePath();",
          "    ctx.stroke(); if (points.length >= 3) ctx.fill();",
          "  }",
          "  writeGeometry();",
          "}",
          "function normPos(e){",
          "  var r = canvas.getBoundingClientRect();",
          "  var x = (e.clientX - r.left) / r.width, y = (e.clientY - r.top) / r.height;",
          "  return {x: Math.min(1, Math.max(0, x)), y: Math.min(1, Math.max(0, y)), w: r.width, h: r.height};",
          "}",
          "function hitIndex(e){",
          "  var p = normPos(e);",
          "  for (var i = points.length - 1; i >= 0; i--) {",
          "    var dx = (points[i][0] - p.x) * p.w, dy = (points[i][1] - p.y) * p.h;",
          "    if (dx*dx + dy*dy < 100) return i;",
          "  }",
          "  return -1;",
          "}",
          "var dragIdx = -1, skipClick = false;",
          "canvas.addEventListener('mousedown', function(e){",
          "  var i = hitIndex(e);",
          "  if (i >= 0) { dragIdx = i; e.preventDefault(); }",
          "});",
          "window.addEventListener('mousemove', function(e){",
          "  if (dragIdx < 0) return;",
          "  var p = normPos(e);",
          "  points[dragIdx] = [p.x, p.y];",
          "  skipClick = true;",
          "  redraw();",
          "});",
          "window.addEventListener('mouseup', function(){ dragIdx = -1; });",
          "canvas.addEventListener('click', function(e){",
          "  if (skipClick) { skipClick = false; return; }",
          "  if (hitIndex(e) >= 0) return;",
          "  var p = normPos(e), x = p.x, y = p.y;",
          "  if (isLine()) { points = points.length >= 2 ? [[x,y]] : points.concat([[x,y]]); }",
          "  else { points.push([x,y]); }",
          "  redraw();",
          "});",
          "document.getElementById('rule-clear').addEventListener('click', function(){ points = []; redraw(); });",
          "document.getElementById('rule-finish').addEventListener('click', function(){ writeGeometry(); redraw(); });",
          "kindEl.addEventListener('change', function(){ points = []; syncVisibility(); redraw(); });",
          "document.getElementById('rule-direction').addEventListener('change', writeGeometry);",
          "motionEl.addEventListener('change', writeGeometry);",
          "document.querySelectorAll('.rule-class').forEach(function(cb){",
          "  cb.addEventListener('change', function(){",
          "    var vals = Array.prototype.slice.call(document.querySelectorAll('.rule-class'))",
          "      .filter(function(c){return c.checked;}).map(function(c){return c.value;});",
          "    classesEl.value = vals.join(',');",
          "  });",
          "});",
          "syncVisibility(); redraw();",
          "})();"
        ]
