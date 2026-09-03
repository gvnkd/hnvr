/* /Timeline — unified archive timeline with a single player
 * (design_docs/12-timeline-archive.md).
 *
 * Self-contained page module: boots on DOMContentLoaded when a
 * [data-timeline] element exists. Canvas renders one coverage lane per
 * camera + a shared event-marker lane + a draggable cursor. Scrubbing
 * swaps the player to the snapshot nearest the cursor (/TimelineThumb
 * 302s to a presigned S3 URL; <img> follows it natively). Releasing
 * the cursor starts hls.js playback of the ACTIVE camera — exactly one
 * camera streams at a time (N concurrent hls.js instances was too
 * laggy). The active camera is chosen from the [data-tl-camera]
 * dropdown, persisted in localStorage and deep-linkable via ?active=.
 * Starting a new drag tears the player down.
 */
(function () {
  "use strict";

  function boot() {
    var root = document.querySelector("[data-timeline]");
    if (!root) return;

    var canvas = root.querySelector("[data-tl-canvas]");
    var ctx = canvas.getContext("2d");
    var labelWrap = document.querySelector("[data-tl-cursor-label]");
    var camSelect = document.querySelector("[data-tl-camera]");
    var stateEl = document.querySelector("[data-tl-state]");
    var img = document.querySelector("[data-tl-thumb]");
    var placeholder = document.querySelector("[data-tl-placeholder]");
    var purgeForm = document.querySelector("[data-tl-purge]");

    var fromMs = Date.parse(root.getAttribute("data-from"));
    var toMs = Date.parse(root.getAttribute("data-to"));
    var cursorMs = Date.parse(root.getAttribute("data-cursor")) || toMs;

    /* Camera list from the dropdown options; spans/markers land on
     * fetchData. Order here = lane order on the canvas. */
    var states = Array.prototype.map.call(
      camSelect ? camSelect.options : [],
      function (opt) {
        return { camId: opt.value, slug: opt.textContent, spans: [], markers: [] };
      }
    );
    function stateOf(camId) {
      return states.filter(function (s) { return s.camId === camId; })[0] || null;
    }

    /* ── active camera: the ONLY one that plays (persisted) ────── */
    var LS_ACTIVE = "hnvr-timeline-active";
    var activeCamId = null;
    try {
      activeCamId = localStorage.getItem(LS_ACTIVE);
    } catch (e) {}
    // Deep link: ?active=<uuid> wins over localStorage.
    var activeParam = new URLSearchParams(location.search).get("active");
    if (activeParam) activeCamId = activeParam;
    if (!stateOf(activeCamId) && states.length) activeCamId = states[0].camId;
    if (camSelect) camSelect.value = activeCamId || "";
    // A deep-linked camera must survive later range switches (which
    // navigate full-page): persist it once honored.
    if (activeParam) saveActive();
    // The custom from/to form carries the active camera as a hidden
    // field so its GET navigation keeps the selection.
    var activeField = document.querySelector("[data-tl-active-field]");
    function syncActiveField() {
      if (activeField) activeField.value = activeCamId || "";
    }
    syncActiveField();

    function saveActive() {
      try {
        localStorage.setItem(LS_ACTIVE, activeCamId || "");
      } catch (e) {}
    }
    function syncPurgeForm() {
      if (!purgeForm) return;
      var st = stateOf(activeCamId);
      if (!st) return;
      // Per-camera purge_archive grant (design_docs/13): the view emits
      // the granted camera ids; hide the button for the rest.
      var purgeCams = (purgeForm.getAttribute("data-purge-cams") || "").split(",");
      if (purgeCams.indexOf(st.camId) === -1) {
        purgeForm.hidden = true;
        return;
      }
      purgeForm.hidden = false;
      purgeForm.setAttribute(
        "action",
        HNVR.u("/PurgeRecording?purgeCameraId=" + encodeURIComponent(st.camId))
      );
      purgeForm.setAttribute(
        "data-confirm",
        "Purge " + st.slug + " recordings in the current window?"
      );
    }
    function setActive(camId, autoplay) {
      if (camId === activeCamId) return;
      stopPlayback();
      activeCamId = camId;
      saveActive();
      syncActiveField();
      if (camSelect && camSelect.value !== camId) camSelect.value = camId;
      syncPurgeForm();
      draw(); // marker lane shows only the active camera
      if (autoplay) playActive();
      else updatePlayer(cursorMs);
    }
    if (camSelect) {
      camSelect.addEventListener("change", function () {
        setActive(camSelect.value, true);
      });
    }
    syncPurgeForm();

    function setState(txt) {
      if (stateEl && stateEl.textContent !== txt) stateEl.textContent = txt;
    }
    function showPlaceholder(txt) {
      if (!placeholder) return;
      img.hidden = true;
      placeholder.hidden = false;
      placeholder.textContent = txt;
    }
    function showThumb(url) {
      placeholder.hidden = true;
      img.hidden = false;
      img.src = url;
    }
    function coveredAt(camId, ms) {
      var st = stateOf(camId);
      return (
        !!st &&
        st.spans.some(function (s) {
          return ms >= s.start && ms <= s.end;
        })
      );
    }

    /* ── playback (single player) ─────────────────────────────── */
    /* Playlists are short windows (not the whole range): when the
     * playhead never advances — old recordings with skewed A/V
     * timestamps can make MSE appends fail with
     * bufferAppendNoProgress — hls.js otherwise races through the
     * ENTIRE playlist (measured: ~1 GB in seconds) while showing a
     * black screen. A 10 min window + hard buffer caps bound the
     * damage; reaching the window end loads the next one (chaining).
     * The first playlist entry is the segment COVERING the cursor
     * (server: endTs > from), so playback begins at most ~one
     * segment (~1 s) early. */
    var PLAYLIST_MAX_MS = 10 * 60 * 1000;
    var HLS_CONFIG = {
      maxBufferLength: 30,
      maxMaxBufferLength: 60,
      maxBufferSize: 60 * 1000 * 1000,
      backBufferLength: 30,
      // Old recordings: EXTINF (DB wall-clock) vs real content drift
      // leaves sub-second holes all over the timeline; the default
      // 3 nudges / 2 s seek-hole cap die on the first unlucky one.
      maxBufferHole: 0.6,
      maxSeekHole: 4,
      nudgeMaxRetry: 12,
    };
    var MAX_BAD_APPENDS = 40;
    var hls = null;
    var video = null;
    var windowEndMs = 0;
    var playToken = 0;
    function stopPlayback() {
      playToken++;
      if (hls) {
        hls.destroy();
        hls = null;
      }
      if (video) {
        video.remove();
        video = null;
      }
    }
    function startPlayback(ms) {
      stopPlayback();
      if (!activeCamId || !coveredAt(activeCamId, ms)) {
        // Chain boundary landing in a coverage gap.
        showPlaceholder("no recording");
        setState("gap");
        return;
      }
      var from = new Date(ms).toISOString();
      windowEndMs = Math.min(toMs, ms + PLAYLIST_MAX_MS);
      var to = new Date(windowEndMs).toISOString();
      var src = HNVR.u(
        "/PlaylistArchive?cameraId=" +
        encodeURIComponent(activeCamId) +
        "&from=" +
        encodeURIComponent(from) +
        "&to=" +
        encodeURIComponent(to)
      );
      video = document.createElement("video");
      // Muted autoplay always starts (engagement-gated otherwise);
      // controls let the user unmute.
      video.muted = true;
      video.autoplay = true;
      video.controls = true;
      video.playsInline = true;
      video.className = "tl-player-video";
      // Window end reached and more range remains → chain the next
      // playlist window from where this one stopped.
      video.addEventListener("ended", function () {
        if (windowEndMs < toMs && video) {
          setState("loading next window…");
          startPlayback(windowEndMs);
        } else {
          setState("ended");
        }
      });
      img.hidden = true;
      placeholder.hidden = true;
      document.querySelector(".tl-player-body").appendChild(video);
      HNVR.zoompan(video);
      setState("connecting…");
      var myHls = null;
      var badAppends = 0;
      /* Old recordings can start with a hole at playlist position 0
       * (first fragment's A/V timestamps don't reach 0), and hls.js's
       * gap nudge only works once playback has STARTED — so autoplay
       * sits on a black frame forever. Kick: jump to the first
       * buffered position and force play() until 'playing' fires. */
      var started = false;
      video.addEventListener("playing", function () {
        started = true;
      });
      function kickStart() {
        if (started || !video || !video.buffered.length) return;
        var first = video.buffered.start(0);
        if (video.currentTime + 0.25 < first) {
          try {
            video.currentTime = first + 0.05;
          } catch (e) {}
        }
        if (video.paused) video.play().catch(function () {});
      }
      // hls.js first: its buffer caps + kickStart protect us from old
      // recordings' timestamp quirks. Native HLS is the Safari-only
      // fallback (chromium answers "maybe" for the MIME but its native
      // path storms through the whole playlist with a black frame).
      if (window.Hls && Hls.isSupported()) {
        /* Server EXTINFs are DB wall-clock and drift from real media
         * durations; hls.js positions by cumulative EXTINF, so the
         * timeline gets holes/overlaps. HNVR.hlsArchive repairs the
         * playlist (range-GETs moof heads for true durations) and
         * detects legacy-skewed audio windows to strip audio up-front
         * (app.js). */
        var token = ++playToken;
        setState("indexing…");
        HNVR.hlsArchive(Hls, video, src, HLS_CONFIG).then(function (h) {
          if (token !== playToken) {
            h.destroy();
            return;
          }
          myHls = h;
          hls = h;
          setState("connecting…");
          h.on(Hls.Events.BUFFER_APPENDED, function () {
            if (hls === myHls) kickStart();
          });
          h.on(Hls.Events.MANIFEST_PARSED, function () {
            if (hls === myHls) setState("playing");
          });
          h.on(Hls.Events.ERROR, function (_, d) {
            if (hls !== myHls) return;
            // Self-healing gap skips — routine on legacy recordings, not
            // worth flashing on the state line.
            if (
              d.details === "bufferSeekOverHole" ||
              d.details === "bufferNudgeOnStall" ||
              d.details === "bufferStalledError"
            )
              return;
            if (
              d.details === "bufferAppendNoProgress" ||
              d.details === "bufferAppendError" ||
              d.details === "bufferFullError"
            ) {
              // MSE rejected/overlapped the segment. Old recordings with
              // skewed A/V timestamps do this per fragment; without a
              // guard hls.js retries forever while downloading the whole
              // window — the 1 GB / black-screen storm. Only fatal-ize
              // while playback has never started: once the playhead
              // moves, overlap errors are benign.
              if (video && video.currentTime > 0) return;
              badAppends++;
              if (badAppends > MAX_BAD_APPENDS) {
                stopPlayback();
                showPlaceholder("recording unreadable (bad timestamps)");
                setState("error");
              }
              return;
            }
            if (d.fatal) {
              console.warn("timeline hls fatal:", d.type, d.details, d.error && d.error.message);
              stopPlayback();
              showPlaceholder("no recording");
              setState("gap");
            } else {
              setState("warn: " + d.details);
            }
          });
        });
      } else if (video.canPlayType("application/vnd.apple.mpegurl")) {
        video.src = src;
        setState("playing (native HLS)");
      } else {
        setState("HLS unsupported");
      }
    }
    function playActive() {
      if (activeCamId && coveredAt(activeCamId, cursorMs)) startPlayback(cursorMs);
      else stopPlayback();
    }

    /* ── thumbnail updates (debounced, token-guarded) ─────────── */
    var debounceTimer = null;
    var thumbToken = 0;
    function scheduleThumb() {
      if (debounceTimer) clearTimeout(debounceTimer);
      debounceTimer = setTimeout(function () {
        updatePlayer(cursorMs);
      }, 150);
    }
    function updatePlayer(ms) {
      if (video) return; // playing — leave the video alone
      if (!activeCamId) return;
      if (!coveredAt(activeCamId, ms)) {
        showPlaceholder("no recording");
        setState("gap");
        return;
      }
      var token = ++thumbToken;
      var url = HNVR.u(
        "/TimelineThumb?cameraId=" +
        encodeURIComponent(activeCamId) +
        "&t=" +
        encodeURIComponent(new Date(ms).toISOString())
      );
      img.onload = function () {
        if (token !== thumbToken || video) return;
        setState("snapshot " + HNVR.formatTs(new Date(ms).toISOString(), "time"));
      };
      img.onerror = function () {
        if (token !== thumbToken || video) return;
        showPlaceholder("no frame");
        setState("gap");
      };
      showThumb(url);
    }

    /* ── data fetch ───────────────────────────────────────────── */
    function fetchData() {
      var url = HNVR.u(
        "/TimelineData?from=" +
        encodeURIComponent(new Date(fromMs).toISOString()) +
        "&to=" +
        encodeURIComponent(new Date(toMs).toISOString())
      );
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
          updatePlayer(cursorMs);
        });
    }

    /* ── canvas rendering ─────────────────────────────────────── */
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

      // Coverage lanes (active camera's lane is accented)
      states.forEach(function (st, i) {
        var y = g.topPad + i * (g.laneH + g.gap);
        ctx.fillStyle = border;
        ctx.globalAlpha = 0.35;
        ctx.fillRect(0, y, w, g.laneH);
        ctx.globalAlpha = 1;
        ctx.fillStyle = st.camId === activeCamId ? accent : ok;
        st.spans.forEach(function (s) {
          var x0 = Math.max(0, xOf(s.start, w));
          var x1 = Math.min(w, xOf(s.end, w));
          if (x1 > x0) ctx.fillRect(x0, y, Math.max(1, x1 - x0), g.laneH);
        });
        ctx.fillStyle = textCol;
        ctx.globalAlpha = st.camId === activeCamId ? 1 : 0.6;
        ctx.font = "10px sans-serif";
        ctx.fillText(st.slug, 4, y + g.laneH - 3);
        ctx.globalAlpha = 1;
      });

      // Event markers (active camera only — the lanes give the full
      // coverage picture, the markers answer "what happened HERE").
      var my = g.topPad + states.length * (g.laneH + g.gap);
      var activeSt = stateOf(activeCamId);
      if (activeSt) {
        ctx.fillStyle = accent;
        activeSt.markers.forEach(function (m) {
          var x = xOf(Date.parse(m.ts), w);
          ctx.beginPath();
          ctx.moveTo(x, my);
          ctx.lineTo(x - 4, my + 8);
          ctx.lineTo(x + 4, my + 8);
          ctx.closePath();
          ctx.fill();
        });
      }

      // Hover position (thumbnail preview target)
      if (hoverMs !== null && !dragging) {
        var hx = xOf(hoverMs, w);
        ctx.strokeStyle = textCol;
        ctx.globalAlpha = 0.35;
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(hx, 0);
        ctx.lineTo(hx, g.height - 14);
        ctx.stroke();
        ctx.globalAlpha = 1;
      }

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
    var downAt = 0;
    var hoverMs = null;
    var hoverToken = 0;
    var hoverTimer = null;
    // Floating thumbnail preview that follows mouse hover over the
    // timeline (YouTube-style scrub preview; drag still owns the player).
    var hover = document.createElement("div");
    hover.className = "tl-hover-preview";
    hover.hidden = true;
    hover.innerHTML = '<img alt="" hidden /><div class="tl-hover-time muted"></div>';
    root.appendChild(hover);
    var hoverImg = hover.querySelector("img");
    var hoverTime = hover.querySelector(".tl-hover-time");
    function clampCursor(ms) {
      return Math.max(fromMs, Math.min(toMs, ms));
    }
    function positionHover(x) {
      var w = root.clientWidth;
      var bw = Math.min(170, w); // preview width + border, keep inside the wrap
      hover.style.left = Math.max(bw / 2, Math.min(w - bw / 2, x)) + "px";
    }
    function updateHover(ms) {
      hoverTime.textContent = HNVR.formatTs(new Date(ms).toISOString());
      if (!activeCamId || !coveredAt(activeCamId, ms)) {
        hoverImg.hidden = true;
        return;
      }
      var token = ++hoverToken;
      hoverImg.onload = function () {
        if (token !== hoverToken) return;
        hoverImg.hidden = false;
      };
      hoverImg.onerror = function () {
        if (token !== hoverToken) return;
        hoverImg.hidden = true;
      };
      hoverImg.src = HNVR.u(
        "/TimelineThumb?cameraId=" +
        encodeURIComponent(activeCamId) +
        "&t=" +
        encodeURIComponent(new Date(ms).toISOString())
      );
    }
    function seekTo(ms) {
      cursorMs = clampCursor(ms);
      draw();
      updateLabel();
      scheduleThumb();
    }
    canvas.addEventListener("pointerdown", function (e) {
      dragging = true;
      hover.hidden = true;
      downX = e.clientX;
      downAt = Date.now();
      canvas.setPointerCapture(e.pointerId);
      stopPlayback(); // new scrub: back to thumbnail mode
      var rect = canvas.getBoundingClientRect();
      seekTo(msOf(e.clientX - rect.left, rect.width));
    });
    canvas.addEventListener("pointermove", function (e) {
      var rect = canvas.getBoundingClientRect();
      if (dragging) {
        seekTo(msOf(e.clientX - rect.left, rect.width));
        return;
      }
      // Hover: light line + debounced thumbnail preview at that time.
      hoverMs = clampCursor(msOf(e.clientX - rect.left, rect.width));
      hover.hidden = false;
      positionHover(e.clientX - rect.left);
      hoverTime.textContent = HNVR.formatTs(new Date(hoverMs).toISOString());
      draw();
      if (hoverTimer) clearTimeout(hoverTimer);
      hoverTimer = setTimeout(function () {
        if (hoverMs !== null && !dragging) updateHover(hoverMs);
      }, 120);
    });
    canvas.addEventListener("pointerleave", function () {
      hoverMs = null;
      hover.hidden = true;
      hoverImg.hidden = true;
      if (hoverTimer) clearTimeout(hoverTimer);
      draw();
    });
    canvas.addEventListener("pointerup", function (e) {
      if (!dragging) return;
      dragging = false;
      var rect = canvas.getBoundingClientRect();
      var moved = Math.abs(e.clientX - downX);
      if (moved < 4) {
        // Click, not a drag: event-marker hit test wins. Touch gets a
        // wider tolerance (finger vs cursor) and long-press stands in
        // for shift-click (no modifier keys on phones).
        var mx = e.clientX - rect.left;
        var isTouch = e.pointerType === "touch";
        var tol = isTouch ? 14 : 8;
        var longPress = isTouch && Date.now() - downAt > 600;
        var g = laneGeom();
        var my = g.topPad + states.length * (g.laneH + g.gap);
        var relY = e.clientY - rect.top;
        if (relY >= my - 2 && relY <= my + g.markerH) {
          var hit = null;
          var activeSt = stateOf(activeCamId);
          if (activeSt)
            activeSt.markers.forEach(function (m) {
              var x = xOf(Date.parse(m.ts), rect.width);
              if (Math.abs(x - mx) < tol) hit = m;
            });
          if (hit) {
            if ((e.shiftKey || longPress) && hit.clipId) {
              window.location.href = HNVR.u("/PlayerEventClip?clipId=" + hit.clipId);
              return;
            }
            seekTo(Date.parse(hit.ts));
            playActive();
            return;
          }
        }
      }
      // Release: the active camera starts archive playback from the
      // cursor time.
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

    // Jump to the previous/next event marker of the active camera and
    // play from there (same as a marker click). Marker order from
    // TimelineData is newest-first — search order-agnostically.
    function jumpEvent(dir) {
      var st = stateOf(activeCamId);
      if (!st || !st.markers.length) {
        setState("no events");
        return;
      }
      var best = null;
      st.markers.forEach(function (m) {
        var t = Date.parse(m.ts);
        if (dir < 0 && t < cursorMs - 500 && (best === null || t > best)) best = t;
        if (dir > 0 && t > cursorMs + 500 && (best === null || t < best)) best = t;
      });
      if (best === null) {
        setState(dir < 0 ? "no earlier event" : "no later event");
        return;
      }
      seekTo(best);
      playActive();
    }
    var prevBtn = document.querySelector("[data-tl-prev-event]");
    var nextBtn = document.querySelector("[data-tl-next-event]");
    if (prevBtn)
      prevBtn.addEventListener("click", function () {
        jumpEvent(-1);
      });
    if (nextBtn)
      nextBtn.addEventListener("click", function () {
        jumpEvent(1);
      });

    // Panel fullscreen (range + player + timeline together).
    var fsBtn = document.querySelector("[data-tl-fs]");
    var shell = document.querySelector("[data-tl-shell]");
    if (fsBtn && shell) {
      fsBtn.addEventListener("click", function () {
        HNVR.toggleFullscreen(shell);
      });
    }

    /* Range presets: navigate centered on the CURRENT cursor — the
     * rendered hrefs carry the page-load cursor, which goes stale the
     * moment the user scrubs. */
    document.querySelectorAll("[data-tl-preset]").forEach(function (a) {
      a.addEventListener("click", function (e) {
        e.preventDefault();
        var secs = parseInt(a.getAttribute("data-tl-preset"), 10);
        if (!secs) return;
        var half = (secs / 2) * 1000;
        var f = new Date(cursorMs - half).toISOString();
        var t = new Date(cursorMs + half).toISOString();
        var c = new Date(cursorMs).toISOString();
        window.location.href = HNVR.u(
          "/Timeline?from=" + encodeURIComponent(f) +
          "&to=" + encodeURIComponent(t) +
          "&t=" + encodeURIComponent(c) +
          "&active=" + encodeURIComponent(activeCamId || "")
        );
      });
    });

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
