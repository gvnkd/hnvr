/* /Timeline — unified multi-camera archive timeline
 * (design_docs/12-timeline-archive.md, Phase B: read path, Phase C:
 * sync playback).
 *
 * Self-contained page module: boots on DOMContentLoaded when a
 * [data-timeline] element exists. Canvas renders one coverage lane per
 * camera + a shared event-marker lane + a draggable cursor. Scrubbing
 * swaps each enabled tile to the snapshot nearest the cursor
 * (/TimelineThumb 302s to a presigned S3 URL; <img> follows it
 * natively). Releasing the cursor starts hls.js playback on the ACTIVE
 * camera only (one stream at a time — N concurrent hls.js instances
 * was too laggy); click a tile to make it active. Starting a new drag
 * tears the player down.
 */
(function () {
  "use strict";

  function boot() {
    var root = document.querySelector("[data-timeline]");
    if (!root) return;

    var canvas = root.querySelector("[data-tl-canvas]");
    var ctx = canvas.getContext("2d");
    var labelWrap = document.querySelector("[data-tl-cursor-label]");
    var tiles = Array.prototype.slice.call(
      document.querySelectorAll("[data-tl-tile]")
    );

    var fromMs = Date.parse(root.getAttribute("data-from"));
    var toMs = Date.parse(root.getAttribute("data-to"));
    var cursorMs = Date.parse(root.getAttribute("data-cursor")) || toMs;

    /* ── disabled cameras (persisted) ─────────────────────────── */
    var LS_KEY = "hnvr-timeline-disabled";
    var LS_ACTIVE = "hnvr-timeline-active";
    function loadDisabled() {
      try {
        return JSON.parse(localStorage.getItem(LS_KEY) || "[]");
      } catch (e) {
        return [];
      }
    }
    var disabled = loadDisabled();
    // Deep link: ?cams=<csv uuids> adds to the disabled set.
    var camsParam = new URLSearchParams(location.search).get("cams");
    if (camsParam) {
      camsParam.split(",").forEach(function (id) {
        if (id && disabled.indexOf(id) < 0) disabled.push(id);
      });
      saveDisabled();
    }
    function saveDisabled() {
      try {
        localStorage.setItem(LS_KEY, JSON.stringify(disabled));
      } catch (e) {}
    }

    /* ── active camera: the ONLY one that plays video (persisted).
     * N concurrent hls.js instances was too laggy — all other tiles
     * stay in thumbnail mode. ─────────────────────────────────── */
    var activeCamId = null;
    try {
      activeCamId = localStorage.getItem(LS_ACTIVE);
    } catch (e) {}
    // Deep link: ?active=<uuid> wins over localStorage.
    var activeParam = new URLSearchParams(location.search).get("active");
    if (activeParam) activeCamId = activeParam;
    function saveActive() {
      try {
        localStorage.setItem(LS_ACTIVE, activeCamId || "");
      } catch (e) {}
    }
    function isActive(st) {
      return st.camId === activeCamId;
    }
    function setActive(st, autoplay) {
      activeCamId = st.camId;
      saveActive();
      states.forEach(function (s) {
        s.el.classList.toggle("tl-active", isActive(s));
        if (!isActive(s)) stopPlayback(s);
      });
      if (autoplay) playActive();
    }

    /* ── per-tile state ───────────────────────────────────────── */
    var states = tiles.map(function (tile) {
      var st = {
        el: tile,
        camId: tile.getAttribute("data-cam-id"),
        slug: tile.getAttribute("data-slug"),
        img: tile.querySelector("[data-tl-thumb]"),
        placeholder: tile.querySelector("[data-tl-placeholder]"),
        stateEl: tile.querySelector("[data-tl-state]"),
        toggle: tile.querySelector("[data-tl-toggle]"),
        thumbToken: 0,
        spans: [],
        markers: [],
        hls: null,
        video: null,
      };
      st.toggle.checked = disabled.indexOf(st.camId) < 0;
      st.toggle.addEventListener("change", function () {
        var i = disabled.indexOf(st.camId);
        if (st.toggle.checked && i >= 0) disabled.splice(i, 1);
        if (!st.toggle.checked && i < 0) disabled.push(st.camId);
        saveDisabled();
        if (!st.toggle.checked) stopPlayback(st);
        updateTile(st, cursorMs);
      });
      st.img.addEventListener("error", function () {
        showPlaceholder(st, "no frame");
        setState(st, "gap");
      });
      // Click the tile (anywhere but the toggle) to make it the active
      // (streaming) camera and start playback at the cursor. Clicking
      // the already-active tile is a no-op (don't restart its stream).
      st.el.addEventListener("click", function (e) {
        if (e.target.closest("[data-tl-toggle]") || e.target.closest(".tl-purge-btn")) return;
        if (isActive(st)) return;
        setActive(st, true);
      });
      return st;
    });
    // Default active camera: first tile when nothing persisted/linked.
    if (!states.some(isActive) && states.length) activeCamId = states[0].camId;
    states.forEach(function (s) {
      s.el.classList.toggle("tl-active", isActive(s));
    });
    function isEnabled(st) {
      return disabled.indexOf(st.camId) < 0;
    }
    function setState(st, txt) {
      if (st.stateEl.textContent !== txt) st.stateEl.textContent = txt;
    }
    function showPlaceholder(st, txt) {
      st.img.hidden = true;
      st.placeholder.hidden = false;
      st.placeholder.textContent = txt;
    }
    function showThumb(st, url) {
      st.placeholder.hidden = true;
      st.img.hidden = false;
      st.img.src = url;
    }
    function coveredAt(st, ms) {
      return st.spans.some(function (s) {
        return ms >= s.start && ms <= s.end;
      });
    }

    /* ── playback (Phase C) ───────────────────────────────────── */
    /* Playlist windows start at the cursor; the first playlist entry
     * is the segment COVERING the cursor (server: endTs > from), so
     * playback begins at most ~one segment (~1 s) early. hls.js
     * startPosition can't do better without segment-boundary data. */
    var PLAYLIST_MAX_MS = 6 * 3600 * 1000; // server cap, design 05
    function stopPlayback(st) {
      if (st.hls) {
        st.hls.destroy();
        st.hls = null;
      }
      if (st.video) {
        st.video.remove();
        st.video = null;
      }
    }
    function stopAllPlayback() {
      states.forEach(stopPlayback);
    }
    function startPlayback(st, ms) {
      stopPlayback(st);
      if (!isEnabled(st) || !coveredAt(st, ms)) return;
      var from = new Date(ms).toISOString();
      var to = new Date(Math.min(toMs, ms + PLAYLIST_MAX_MS)).toISOString();
      var src =
        "/PlaylistArchive?cameraId=" +
        encodeURIComponent(st.camId) +
        "&from=" +
        encodeURIComponent(from) +
        "&to=" +
        encodeURIComponent(to);
      var video = document.createElement("video");
      video.muted = true;
      video.autoplay = true;
      video.playsInline = true;
      video.className = "tl-tile-video";
      st.img.hidden = true;
      st.placeholder.hidden = true;
      st.el.querySelector(".tl-tile-body").appendChild(video);
      st.video = video;
      setState(st, "connecting…");
      if (video.canPlayType("application/vnd.apple.mpegurl")) {
        video.src = src;
        setState(st, "playing (native HLS)");
      } else if (window.Hls && Hls.isSupported()) {
        var hls = new Hls();
        st.hls = hls;
        hls.loadSource(src);
        hls.attachMedia(video);
        hls.on(Hls.Events.MANIFEST_PARSED, function () {
          if (st.hls === hls) setState(st, "playing");
        });
        hls.on(Hls.Events.ERROR, function (_, d) {
          if (st.hls !== hls) return;
          if (d.fatal) {
            stopPlayback(st);
            showPlaceholder(st, "no recording");
            setState(st, "gap");
          } else {
            setState(st, "warn: " + d.details);
          }
        });
      } else {
        setState(st, "HLS unsupported");
      }
    }
    function playActive() {
      states.forEach(function (st) {
        if (isActive(st) && isEnabled(st) && coveredAt(st, cursorMs)) startPlayback(st, cursorMs);
        else stopPlayback(st);
      });
    }

    /* ── thumbnail updates (debounced, token-guarded) ─────────── */
    var debounceTimer = null;
    function scheduleThumbs() {
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = setTimeout(function () {
        states.forEach(function (st) {
          updateTile(st, cursorMs);
        });
      }, 150);
    }
    function updateTile(st, ms) {
      if (st.video) return; // playing — leave the video alone
      if (!isEnabled(st)) {
        showPlaceholder(st, "disabled");
        setState(st, "disabled");
        return;
      }
      if (!coveredAt(st, ms)) {
        showPlaceholder(st, "no recording");
        setState(st, "gap");
        return;
      }
      var token = ++st.thumbToken;
      var url =
        "/TimelineThumb?cameraId=" +
        encodeURIComponent(st.camId) +
        "&t=" +
        encodeURIComponent(new Date(ms).toISOString());
      st.img.onload = function () {
        if (token !== st.thumbToken) return;
        setState(st, "snapshot " + HNVR.formatTs(new Date(ms).toISOString(), "time"));
      };
      showThumb(st, url);
    }

    /* ── data fetch ───────────────────────────────────────────── */
    function fetchData() {
      var url =
        "/TimelineData?from=" +
        encodeURIComponent(new Date(fromMs).toISOString()) +
        "&to=" +
        encodeURIComponent(new Date(toMs).toISOString());
      return fetch(url, { credentials: "same-origin" })
        .then(function (r) {
          return r.json();
        })
        .then(function (data) {
          states.forEach(function (st) {
            var cam = data.cameras.filter(function (c) {
              return c.id === st.camId;
            })[0];
            st.spans = cam
              ? cam.spans.map(function (s) {
                  return { start: Date.parse(s.start), end: Date.parse(s.end) };
                })
              : [];
            st.markers = cam ? cam.events : [];
          });
          draw();
          states.forEach(function (st) {
            updateTile(st, cursorMs);
          });
        });
    }

    /* ── canvas rendering ─────────────────────────────────────── */
    var PALETTE = [
      "#38bdf8",
      "#34d399",
      "#fbbf24",
      "#f87171",
      "#a78bfa",
      "#22d3ee",
      "#fb923c",
      "#e879f9",
    ];
    function cssVar(name, fallback) {
      var v = getComputedStyle(document.documentElement)
        .getPropertyValue(name)
        .trim();
      return v || fallback;
    }
    function laneGeom() {
      var n = states.length;
      var laneH = 14;
      var gap = 6;
      var topPad = 8;
      var markerH = 18;
      var bottomPad = 22;
      var h = topPad + n * (laneH + gap) + markerH + bottomPad;
      return { laneH: laneH, gap: gap, topPad: topPad, markerH: markerH, height: h };
    }
    function xOf(ms, w) {
      return ((ms - fromMs) / (toMs - fromMs)) * w;
    }
    function msOf(x, w) {
      return fromMs + (x / w) * (toMs - fromMs);
    }
    function resize() {
      var g = laneGeom();
      var dpr = window.devicePixelRatio || 1;
      var w = root.clientWidth;
      canvas.width = Math.round(w * dpr);
      canvas.height = Math.round(g.height * dpr);
      canvas.style.width = w + "px";
      canvas.style.height = g.height + "px";
      ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      draw();
    }
    function draw() {
      var w = root.clientWidth;
      if (!w) return;
      var g = laneGeom();
      var accent = cssVar("--accent", "#38bdf8");
      var border = cssVar("--border", "#232a38");
      var ok = cssVar("--ok", "#34d399");
      var textCol = cssVar("--text", "#e6eaf2");
      ctx.clearRect(0, 0, w, g.height);

      // Coverage lanes
      states.forEach(function (st, i) {
        var y = g.topPad + i * (g.laneH + g.gap);
        ctx.fillStyle = border;
        ctx.globalAlpha = 0.35;
        ctx.fillRect(0, y, w, g.laneH);
        ctx.globalAlpha = 1;
        ctx.fillStyle = ok;
        st.spans.forEach(function (s) {
          var x0 = Math.max(0, xOf(s.start, w));
          var x1 = Math.min(w, xOf(s.end, w));
          if (x1 > x0) ctx.fillRect(x0, y, Math.max(1, x1 - x0), g.laneH);
        });
        ctx.fillStyle = textCol;
        ctx.globalAlpha = 0.6;
        ctx.font = "10px sans-serif";
        ctx.fillText(st.slug, 4, y + g.laneH - 3);
        ctx.globalAlpha = 1;
      });

      // Event markers
      var my = g.topPad + states.length * (g.laneH + g.gap);
      states.forEach(function (st, i) {
        ctx.fillStyle = PALETTE[i % PALETTE.length];
        st.markers.forEach(function (m) {
          var x = xOf(Date.parse(m.ts), w);
          ctx.beginPath();
          ctx.moveTo(x, my);
          ctx.lineTo(x - 4, my + 8);
          ctx.lineTo(x + 4, my + 8);
          ctx.closePath();
          ctx.fill();
        });
      });

      // Cursor
      var cx = xOf(cursorMs, w);
      ctx.strokeStyle = accent;
      ctx.lineWidth = 2;
      ctx.beginPath();
      ctx.moveTo(cx, 0);
      ctx.lineTo(cx, g.height - 14);
      ctx.stroke();
      ctx.fillStyle = accent;
      ctx.fillRect(cx - 5, g.height - 14, 10, 10);
    }

    /* ── cursor label ─────────────────────────────────────────── */
    function updateLabel() {
      if (!labelWrap) return;
      var span = labelWrap.querySelector("[data-utc-ts]");
      if (!span) return;
      span.setAttribute("data-utc-ts", new Date(cursorMs).toISOString());
      span.textContent = HNVR.formatTs(new Date(cursorMs).toISOString());
    }

    /* ── pointer interaction ──────────────────────────────────── */
    var dragging = false;
    var downX = 0;
    var downCursor = 0;
    function clampCursor(ms) {
      return Math.max(fromMs, Math.min(toMs, ms));
    }
    function seekTo(ms) {
      cursorMs = clampCursor(ms);
      draw();
      updateLabel();
      scheduleThumbs();
    }
    canvas.addEventListener("pointerdown", function (e) {
      dragging = true;
      downX = e.clientX;
      downCursor = cursorMs;
      canvas.setPointerCapture(e.pointerId);
      stopAllPlayback(); // new scrub: tiles return to thumbnail mode
      var rect = canvas.getBoundingClientRect();
      seekTo(msOf(e.clientX - rect.left, rect.width));
    });
    canvas.addEventListener("pointermove", function (e) {
      if (!dragging) return;
      var rect = canvas.getBoundingClientRect();
      seekTo(msOf(e.clientX - rect.left, rect.width));
    });
    canvas.addEventListener("pointerup", function (e) {
      if (!dragging) return;
      dragging = false;
      var rect = canvas.getBoundingClientRect();
      var moved = Math.abs(e.clientX - downX);
      if (moved < 4) {
        // Click, not a drag: event-marker hit test wins.
        var mx = e.clientX - rect.left;
        var g = laneGeom();
        var my = g.topPad + states.length * (g.laneH + g.gap);
        var relY = e.clientY - rect.top;
        if (relY >= my - 2 && relY <= my + g.markerH) {
          var hit = null;
          states.forEach(function (st) {
            st.markers.forEach(function (m) {
              var x = xOf(Date.parse(m.ts), rect.width);
              if (Math.abs(x - mx) < 8) hit = m;
            });
          });
          if (hit) {
            if (e.shiftKey && hit.clipId) {
              window.location.href = "/PlayerEventClip?clipId=" + hit.clipId;
              return;
            }
            seekTo(Date.parse(hit.ts));
            playActive();
            return;
          }
        }
      }
      // Release: the active camera starts archive playback from the
      // cursor time; every other tile settles on its thumbnail.
      playActive();
    });
    canvas.addEventListener("pointercancel", function () {
      dragging = false;
    });

    if (window.ResizeObserver) {
      new ResizeObserver(resize).observe(root);
    }
    window.addEventListener("resize", resize);

    // Purge forms use the shared data-confirm gate in app.js.

    resize();
    updateLabel();
    fetchData().then(function () {
      // Deep link with an explicit cursor (e.g. /Events ▶): play
      // immediately instead of sitting in thumbnail mode.
      if (new URLSearchParams(location.search).get("t")) playActive();
    });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", boot);
  } else {
    boot();
  }
})();
