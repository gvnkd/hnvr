/* HNVR web UI — client behavior (no framework, no npm).
 *
 * Loaded without `defer` in <head> so inline page scripts can call
 * HNVR.* helpers (IHP HSX injects page JS as body-level scripts).
 *
 * Features:
 *  - theme switching (midnight/daylight, persisted to localStorage)
 *  - sidebar collapse toggle (persisted)
 *  - dropdown toggle menus ([data-dropdown] / [data-dropdown-button])
 *  - collapsible panels ([data-collapsible] + [data-collapse-trigger],
 *    persisted per data-collapse-id)
 *  - dynamic tables: sortable headers (table[data-sortable]) and
 *    instant text filtering (input[data-table-filter="#id"])
 *  - clickable table rows (tr[data-href], middle-click = new tab)
 *  - dashboard camera wall: low-fps frame polling with crossfade,
 *    IntersectionObserver-gated, exponential backoff on failure
 *  - fullscreen live overlay: FLIP-animated expand from the clicked
 *    card, WHEP WebRTC playback via HNVR.whep()
 *  - event thumbnail lightbox
 *  - viewer timezone: [data-utc-ts] timestamps, topbar clock and
 *    datetime-local filters shown in the profile/browser zone
 */
(function () {
  "use strict";

  var HNVR = (window.HNVR = window.HNVR || {});

  /* ── Themes ─────────────────────────────────────────────────── */
  HNVR.themes = ["midnight", "daylight"];
  HNVR.setTheme = function (name) {
    document.documentElement.setAttribute("data-theme", name);
    try {
      localStorage.setItem("hnvr-theme", name);
    } catch (e) {}
    document.querySelectorAll("[data-theme-option]").forEach(function (el) {
      el.classList.toggle("is-active", el.getAttribute("data-theme-option") === name);
    });
  };

  /* ── Sidebar collapse ───────────────────────────────────────── */
  /* Desktop: .nav-collapsed = icon rail, persisted in localStorage.
   * Mobile (<=900px): the same class means "drawer open" (src.css
   * inverts it); drawer state is NOT persisted and starts closed, so a
   * desktop-collapsed user doesn't get an auto-open drawer on a phone.
   * A JS-created scrim closes the drawer on outside tap. */
  function initSidebar() {
    var shell = document.querySelector(".shell");
    if (!shell) return;
    var mq = window.matchMedia("(max-width: 900px)");
    try {
      if (!mq.matches && localStorage.getItem("hnvr-nav-collapsed") === "1")
        shell.classList.add("nav-collapsed");
    } catch (e) {}
    var scrim = document.createElement("div");
    scrim.className = "nav-scrim";
    scrim.hidden = true;
    shell.appendChild(scrim);
    function syncScrim() {
      scrim.hidden = !(mq.matches && shell.classList.contains("nav-collapsed"));
    }
    document.querySelectorAll("[data-nav-toggle]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        shell.classList.toggle("nav-collapsed");
        if (!mq.matches) {
          try {
            localStorage.setItem(
              "hnvr-nav-collapsed",
              shell.classList.contains("nav-collapsed") ? "1" : "0"
            );
          } catch (e) {}
        }
        syncScrim();
      });
    });
    scrim.addEventListener("click", function () {
      shell.classList.remove("nav-collapsed");
      syncScrim();
    });
    if (mq.addEventListener) mq.addEventListener("change", syncScrim);
    syncScrim();
  }

  /* ── Dropdown menus ─────────────────────────────────────────── */
  function initDropdowns() {
    document.querySelectorAll("[data-dropdown]").forEach(function (dd) {
      var btn = dd.querySelector("[data-dropdown-button]");
      var menu = dd.querySelector(".dropdown-menu");
      if (!btn || !menu) return;
      menu.hidden = true;
      btn.setAttribute("aria-expanded", "false");
      btn.addEventListener("click", function (e) {
        e.stopPropagation();
        var open = menu.hidden;
        closeAllDropdowns();
        if (open) {
          menu.hidden = false;
          btn.setAttribute("aria-expanded", "true");
        }
      });
    });
    document.addEventListener("click", closeAllDropdowns);
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") closeAllDropdowns();
    });
  }
  function closeAllDropdowns() {
    document.querySelectorAll("[data-dropdown] .dropdown-menu").forEach(function (m) {
      m.hidden = true;
    });
    document.querySelectorAll("[data-dropdown-button]").forEach(function (b) {
      b.setAttribute("aria-expanded", "false");
    });
  }

  /* ── Collapsible panels ─────────────────────────────────────── */
  function initCollapsibles() {
    document.querySelectorAll("[data-collapsible]").forEach(function (panel) {
      var trigger = panel.querySelector("[data-collapse-trigger]");
      if (!trigger) return;
      var id = panel.getAttribute("data-collapse-id");
      var stored = null;
      if (id) {
        try {
          stored = localStorage.getItem("hnvr-collapse-" + id);
        } catch (e) {}
      }
      // Default: open. Only an explicit stored "0" collapses.
      var open = stored !== "0";
      panel.classList.toggle("is-open", open);
      trigger.setAttribute("aria-expanded", open ? "true" : "false");
      trigger.addEventListener("click", function () {
        var nowOpen = panel.classList.toggle("is-open");
        trigger.setAttribute("aria-expanded", nowOpen ? "true" : "false");
        if (id) {
          try {
            localStorage.setItem("hnvr-collapse-" + id, nowOpen ? "1" : "0");
          } catch (e) {}
        }
      });
    });
  }

  /* ── Dynamic tables: sortable headers ───────────────────────── */
  function cellValue(row, idx) {
    var cell = row.children[idx];
    return cell ? cell.textContent.trim() : "";
  }
  function numericish(v) {
    var cleaned = v.replace(/[^0-9.\-]/g, "");
    return cleaned !== "" && !isNaN(parseFloat(cleaned));
  }
  function initSortableTables() {
    document.querySelectorAll("table[data-sortable]").forEach(function (table) {
      var heads = table.querySelectorAll("thead th");
      heads.forEach(function (th, idx) {
        if (th.hasAttribute("data-no-sort")) return;
        th.setAttribute("data-sort", "");
        var arrow = document.createElement("span");
        arrow.className = "sort-arrow";
        arrow.textContent = "▲";
        th.appendChild(arrow);
        th.addEventListener("click", function () {
          var current = th.getAttribute("aria-sort");
          var asc = current !== "ascending";
          heads.forEach(function (h) {
            h.removeAttribute("aria-sort");
          });
          th.setAttribute("aria-sort", asc ? "ascending" : "descending");
          var tbody = table.tBodies[0];
          if (!tbody) return;
          var rows = Array.prototype.slice.call(tbody.rows);
          var numeric = rows.every(function (r) {
            return numericish(cellValue(r, idx));
          });
          rows.sort(function (a, b) {
            var av = cellValue(a, idx);
            var bv = cellValue(b, idx);
            var cmp;
            if (numeric) {
              cmp =
                parseFloat(av.replace(/[^0-9.\-]/g, "")) -
                parseFloat(bv.replace(/[^0-9.\-]/g, ""));
            } else {
              cmp = av.localeCompare(bv);
            }
            return asc ? cmp : -cmp;
          });
          rows.forEach(function (r) {
            tbody.appendChild(r);
          });
        });
      });
    });
  }

  /* ── Dynamic tables: instant text filter ────────────────────── */
  function initTableFilters() {
    document.querySelectorAll("[data-table-filter]").forEach(function (input) {
      var target = document.querySelector(input.getAttribute("data-table-filter"));
      if (!target) return;
      input.addEventListener("input", function () {
        var q = input.value.toLowerCase();
        var tbody = target.tBodies[0];
        if (!tbody) return;
        Array.prototype.forEach.call(tbody.rows, function (row) {
          row.style.display =
            q === "" || row.textContent.toLowerCase().indexOf(q) !== -1 ? "" : "none";
        });
      });
    });
  }

  /* ── Clickable rows ─────────────────────────────────────────── */
  function initRowLinks() {
    document.querySelectorAll("tr[data-href]").forEach(function (row) {
      row.classList.add("row-link");
      if (!row.hasAttribute("tabindex")) row.setAttribute("tabindex", "0");
      row.addEventListener("click", function (e) {
        if (e.target.closest("a, button, input, select, textarea, form, label, .ev-thumb"))
          return;
        var href = row.getAttribute("data-href");
        if (e.metaKey || e.ctrlKey || e.button === 1) window.open(href, "_blank");
        else window.location.href = href;
      });
      row.addEventListener("auxclick", function (e) {
        if (e.button === 1) window.open(row.getAttribute("data-href"), "_blank");
      });
      row.addEventListener("keydown", function (e) {
        if (e.key === "Enter" && e.target === row)
          window.location.href = row.getAttribute("data-href");
      });
    });
  }

  /* ── Shared WHEP client (dashboard overlay + /ShowLive) ─────── */
  /* Reconnecting client: exponential backoff re-offer on connection
   * failure, plus two liveness watchdogs — a connect timeout (no
   * ontrack within 10 s of the SDP answer, e.g. camera dead at the
   * source while the mediamtx path still accepts WHEP) and a
   * frame-arrival watchdog (getStats inbound-rtp framesReceived must
   * keep increasing; a frozen counter means the browser is rendering
   * the last decoded frame of a dead camera).
   *
   * States reported via onState: "connecting", "live",
   * "reconnecting", "error: <msg>". Reconnects are attempted forever
   * until close() — a camera that comes back must resume on its own. */
  HNVR.whep = function (slug, video, onState) {
    var pc = null;
    var closed = false;
    var attempts = 0;
    var retryTimer = null;
    var watchdogTimer = null;
    var connectTimer = null;
    var lastFrames = -1;
    var lastFrameAt = 0;

    function backoffMs() {
      // 2s, 4s, 8s, 16s, 30s, 30s, …
      return Math.min(30000, 1000 * Math.pow(2, Math.min(attempts, 5)));
    }
    function clearTimers() {
      if (retryTimer) { clearTimeout(retryTimer); retryTimer = null; }
      if (watchdogTimer) { clearInterval(watchdogTimer); watchdogTimer = null; }
      if (connectTimer) { clearTimeout(connectTimer); connectTimer = null; }
    }
    function teardown() {
      clearTimers();
      if (pc) {
        try { pc.close(); } catch (e) {}
        pc = null;
      }
    }
    function scheduleReconnect() {
      if (closed) return;
      teardown();
      attempts++;
      onState("reconnecting");
      retryTimer = setTimeout(connect, backoffMs());
    }
    function startWatchdog() {
      lastFrames = -1;
      lastFrameAt = Date.now();
      watchdogTimer = setInterval(function () {
        if (!pc || pc.connectionState !== "connected") return;
        pc.getStats()
          .then(function (stats) {
            var frames = null;
            stats.forEach(function (r) {
              if (r.type === "inbound-rtp" && (r.kind === "video" || r.mediaType === "video"))
                frames = (frames || 0) + (r.framesReceived || 0);
            });
            if (frames === null) return; // stats unavailable — don't kill a good stream
            if (frames !== lastFrames) {
              lastFrames = frames;
              lastFrameAt = Date.now();
            } else if (Date.now() - lastFrameAt > 6000) {
              scheduleReconnect();
            }
          })
          .catch(function () {});
      }, 2000);
    }
    function connect() {
      if (closed) return;
      teardown();
      onState("connecting");
      pc = new RTCPeerConnection();
      pc.addTransceiver("video", { direction: "recvonly" });
      pc.addTransceiver("audio", { direction: "recvonly" });
      pc.ontrack = function (e) {
        video.srcObject = e.streams[0];
        attempts = 0;
        if (connectTimer) { clearTimeout(connectTimer); connectTimer = null; }
        onState("live");
        startWatchdog();
      };
      pc.onconnectionstatechange = function () {
        if (pc.connectionState === "failed" || pc.connectionState === "disconnected")
          scheduleReconnect();
        else if (pc.connectionState === "connected") onState("live");
      };
      pc.createOffer()
        .then(function (o) {
          return pc.setLocalDescription(o);
        })
        .then(function () {
          return new Promise(function (resolve) {
            if (pc.iceGatheringState === "complete") resolve();
            else
              pc.onicegatheringstatechange = function () {
                if (pc.iceGatheringState === "complete") resolve();
              };
          });
        })
        .then(function () {
          return fetch("/whep/" + slug, {
            method: "POST",
            headers: { "Content-Type": "application/sdp" },
            body: pc.localDescription.sdp,
          });
        })
        .then(function (r) {
          if (!r.ok) throw new Error("WHEP POST failed: " + r.status);
          return r.text();
        })
        .then(function (answer) {
          pc.setRemoteDescription({ type: "answer", sdp: answer });
          // Answer accepted but media may never arrive (dead camera
          // behind a live mediamtx path). Re-offer if no track in 10 s.
          connectTimer = setTimeout(scheduleReconnect, 10000);
        })
        .catch(function (e) {
          if (closed) return;
          onState("error: " + e.message);
          attempts++;
          retryTimer = setTimeout(connect, backoffMs());
        });
    }
    connect();
    return {
      close: function () {
        closed = true;
        teardown();
      },
    };
  };

  /* ── Video zoom/pan (wheel = zoom at cursor, LMB drag = pan) ── */
  /* Fullscreen always targets the WRAPPER div, never the <video>
   * element (hardware overlays ignore transforms — see the
   * fullscreenchange comment below). HNVR.toggleFullscreen is the one
   * entry point; zoompan additionally intercepts dblclick on the video
   * so Chrome's UA "dblclick = fullscreen the video element" never
   * bypasses the wrapper. */
  HNVR.toggleFullscreen = function (el) {
    if (!el) return;
    if (document.fullscreenElement) document.exitFullscreen();
    else if (el.requestFullscreen) el.requestFullscreen();
  };

  /* ── Video zoom/pan (wheel = zoom at cursor, LMB drag = pan) ── */
  /* Digital zoom for every player surface (dashboard overlay,
   * /ShowLive, archive player). transform-origin is fixed at 0 0 and
   * the transform is `translate(tx,ty) scale(z)`, so the untransformed
   * layout position of the element is getBoundingClientRect() minus
   * (tx,ty) and a content point p sits at screen rect.left + z*p.
   *
   *  - wheel: zoom in/out by 1.25x per notch around the cursor, clamped
   *    to [1, 8]; pan offsets clamped so the frame never exposes the
   *    black container behind the video.
   *  - LMB drag pans (only when zoomed; at z=1 nothing is intercepted
   *    so click-to-play keeps working). A drag ending in a click event
   *    is swallowed (>4px movement) so panning doesn't toggle pause.
   *  - zoom back out to 1x (wheel down) clears the transform; dblclick
   *    toggles wrapper fullscreen (intercepted in capture phase —
   *    Chrome's own dblclick fullscreens the bare video element, which
   *    breaks zoom via hardware overlay).
   *  - drags starting in the bottom 48 px (native control strip) are
   *    left alone so the scrubber/volume stay usable.
   *
   * Returns { reset() } — overlay close resets the view. */
  HNVR.zoompan = function (video) {
    if (!video || video.dataset.zoompanBound) return null;
    video.dataset.zoompanBound = "1";
    video.style.transformOrigin = "0 0";
    var z = 1,
      tx = 0,
      ty = 0;
    var MAXZ = 8;
    var drag = null,
      moved = 0,
      suppressClick = false;

    function clamp() {
      var W = video.offsetWidth,
        H = video.offsetHeight;
      tx = Math.min(0, Math.max(W - z * W, tx));
      ty = Math.min(0, Math.max(H - z * H, ty));
    }
    function apply() {
      if (z <= 1) {
        z = 1;
        tx = 0;
        ty = 0;
        video.style.transform = "";
        video.classList.remove("is-zoomed");
      } else {
        clamp();
        video.style.transform = "translate(" + tx + "px," + ty + "px) scale(" + z + ")";
        video.classList.add("is-zoomed");
      }
    }

    video.addEventListener(
      "wheel",
      function (e) {
        e.preventDefault();
        var rect = video.getBoundingClientRect();
        var factor = e.deltaY < 0 ? 1.25 : 0.8;
        var z2 = Math.min(MAXZ, Math.max(1, z * factor));
        if (z2 === z) return;
        var s = z2 / z;
        // Keep the content point under the cursor fixed on screen.
        tx += (e.clientX - rect.left) * (1 - s);
        ty += (e.clientY - rect.top) * (1 - s);
        z = z2;
        apply();
      },
      // CAPTURE phase is load-bearing: in fullscreen Chrome's native
      // media controls consume wheel events (volume scroll) inside the
      // shadow root and stop propagation — a bubble-phase listener on
      // the host never fires.
      { passive: false, capture: true }
    );

    video.addEventListener("mousedown", function (e) {
      if (e.button !== 0 || z <= 1) return;
      var rect = video.getBoundingClientRect();
      if (video.controls && (e.clientY - rect.top) / z > video.offsetHeight - 48) return;
      drag = { x: e.clientX, y: e.clientY };
      moved = 0;
      video.classList.add("is-panning");
      e.preventDefault();
    });
    document.addEventListener("mousemove", function (e) {
      if (!drag) return;
      var dx = e.clientX - drag.x,
        dy = e.clientY - drag.y;
      moved += Math.abs(dx) + Math.abs(dy);
      tx += dx;
      ty += dy;
      drag = { x: e.clientX, y: e.clientY };
      apply();
    });
    document.addEventListener("mouseup", function () {
      if (!drag) return;
      drag = null;
      video.classList.remove("is-panning");
      // Expire the flag: if the release happened outside the browser
      // window no click follows, and without a timeout the user's next
      // genuine click would be swallowed instead.
      if (moved > 4) {
        suppressClick = true;
        setTimeout(function () {
          suppressClick = false;
        }, 300);
      }
    });
    // Fullscreen entry/exit changes the element's box — re-clamp the
    // pan offsets so a zoom carried across the boundary can't leave the
    // frame shifted. (Fullscreen targets the WRAPPER div, not the
    // video: a fullscreened <video> can bypass the compositor via a
    // hardware overlay and ignore CSS transforms entirely — that was
    // the "zoom dead in fullscreen, applied on exit" bug.)
    document.addEventListener("fullscreenchange", function () {
      apply();
    });
    // Pointer left the document mid-drag: end the pan (no trailing
    // click exists in that case, so no suppression needed).
    document.addEventListener("mouseleave", function () {
      if (!drag) return;
      drag = null;
      video.classList.remove("is-panning");
    });
    // Swallow the click that trails a pan drag. Must be on window in
    // capture phase: when the drag ends OUTSIDE the video (e.g. on the
    // dashboard overlay backdrop), the browser dispatches the click on
    // the nearest common ancestor of the press/release targets — the
    // overlay itself — and its backdrop-click handler would close the
    // player mid-pan.
    window.addEventListener(
      "click",
      function (e) {
        if (suppressClick) {
          suppressClick = false;
          e.preventDefault();
          e.stopPropagation();
        }
      },
      true
    );

    // dblclick = toggle wrapper fullscreen. Capture phase +
    // stopPropagation is load-bearing: Chrome's media controls toggle
    // VIDEO-element fullscreen on dblclick from inside the shadow root —
    // that path bypasses the wrapper and its hardware overlay ignores
    // the zoom transform. Stopping the event at the host keeps the
    // shadow handler from ever seeing it. The bottom control strip is
    // excluded so control dblclicks behave natively.
    var wrapper =
      video.closest(".video-frame, .live-overlay-video") || video.parentElement;
    video.addEventListener(
      "dblclick",
      function (e) {
        var rect = video.getBoundingClientRect();
        if (video.controls && e.clientY - rect.top > rect.height - 48) return;
        e.preventDefault();
        e.stopPropagation();
        HNVR.toggleFullscreen(wrapper);
      },
      true
    );

    return {
      reset: function () {
        z = 1;
        tx = 0;
        ty = 0;
        apply();
      },
    };
  };

  /* ── Dashboard camera wall: low-fps live frames ─────────────── */
  function liveOverlayOpen() {
    var o = document.getElementById("live-overlay");
    return !!(o && !o.hidden);
  }
  function initLiveFrames() {
    document.querySelectorAll(".cam-live[data-frame-url]").forEach(function (wrap) {
      var url = wrap.getAttribute("data-frame-url");
      var imgs = wrap.querySelectorAll("img");
      if (imgs.length < 2) return;
      var statusBadge = wrap.querySelector(".cam-badge-status");
      var front = 0;
      var visible = false;
      var timer = null;
      var failures = 0;
      var badgeMode = null; // null = server-rendered state still shown

      // The badge is JS-owned once polling starts: the server-rendered
      // text reflects page-load state and can't track liveness.
      // Change-only writes — no DOM churn on every 2 s tick.
      function setBadge(mode) {
        if (!statusBadge || mode === badgeMode) return;
        badgeMode = mode;
        if (mode === "live") {
          statusBadge.className = "badge badge-rec cam-badge-status";
          statusBadge.innerHTML = '<span class="led led-rec"></span>REC';
        } else {
          statusBadge.className = "badge badge-danger cam-badge-status";
          statusBadge.textContent = "NO SIGNAL";
        }
      }

      function interval() {
        // Back off hard when the frame endpoint 404s (analysis off).
        return failures > 3 ? 15000 : 2000;
      }
      function tick() {
        if (!visible) return;
        if (liveOverlayOpen()) {
          if (timer) clearTimeout(timer);
          timer = setTimeout(tick, 500);
          return;
        }
        var next = new Image();
        next.onload = function () {
          failures = 0;
          var back = imgs[1 - front];
          back.src = next.src;
          imgs[front].classList.remove("is-front");
          back.classList.add("is-front");
          front = 1 - front;
          wrap.classList.add("has-signal");
          setBadge("live");
          schedule();
        };
        next.onerror = function () {
          failures++;
          wrap.classList.remove("has-signal");
          setBadge("down");
          schedule();
        };
        next.src = url + (url.indexOf("?") >= 0 ? "&" : "?") + "t=" + Date.now();
      }
      function schedule() {
        if (timer) clearTimeout(timer);
        if (visible) timer = setTimeout(tick, interval());
      }
      var io = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          visible = entry.isIntersecting;
          if (visible) tick();
          else if (timer) {
            clearTimeout(timer);
            timer = null;
          }
        });
      });
      io.observe(wrap);
    });
  }

  /* ── Fitted preview grids: pick the column count that maximizes ──
     tile size for N 16/9 cards, bounded by BOTH the container width
     and the viewport height (the whole wall should fit one screen).
     For each candidate column count c the tile width is
       min( (W-(c-1)g)/c,  ((H-(rows-1)g)/rows - chrome) * 16/9 )
     and the c giving the widest tile wins (ties → fewer columns).
     Applied to .cam-grid; CSS keeps an auto-fill fallback for no-JS. */
  function fitGrid(grid) {
    var cards = grid.children;
    var n = cards.length;
    if (!n) return;
    var cs = getComputedStyle(grid);
    var gap = parseFloat(cs.columnGap) || 0;
    var W = grid.clientWidth;
    var body = cards[0].querySelector(".cam-body");
    var chrome = (body ? body.offsetHeight : 0) + 2; // body row + borders
    var ar = 9 / 16;
    var absTop = grid.getBoundingClientRect().top + window.scrollY;
    var H = window.innerHeight - absTop - 16;
    var bestC = 1;
    var bestW = -1;
    for (var c = 1; c <= n; c++) {
      var rows = Math.ceil(n / c);
      var wWidth = (W - (c - 1) * gap) / c;
      var wHeight = ((H - (rows - 1) * gap) / rows - chrome) / ar;
      var w = Math.min(wWidth, wHeight);
      if (w > bestW + 0.5) {
        bestW = w;
        bestC = c;
      }
    }
    var wFull = (W - (bestC - 1) * gap) / bestC;
    if (bestW < 260) {
      // Absurd budget (tiny window): revert to the CSS auto-fill default.
      grid.style.gridTemplateColumns = "";
      grid.style.justifyContent = "";
    } else if (bestW >= wFull - 1) {
      grid.style.gridTemplateColumns = "repeat(" + bestC + ", 1fr)";
      grid.style.justifyContent = "";
    } else {
      grid.style.gridTemplateColumns =
        "repeat(" + bestC + ", " + Math.floor(bestW) + "px)";
      grid.style.justifyContent = "center";
    }
  }
  function initFitGrids() {
    var grids = Array.prototype.slice.call(document.querySelectorAll(".cam-grid"));
    if (!grids.length) return;
    function relayout() {
      grids.forEach(fitGrid);
    }
    var timer = null;
    window.addEventListener("resize", function () {
      if (timer) clearTimeout(timer);
      timer = setTimeout(relayout, 120);
    });
    relayout();
  }

  /* ── Fullscreen live overlay (FLIP expand from card) ────────── */
  var liveSession = null;
  var livePtz = null;
  var liveZoom = null;
  function openLive(card) {
    var overlay = document.getElementById("live-overlay");
    if (!overlay) return;
    var slug = card.getAttribute("data-slug");
    var camId = card.getAttribute("data-cam-id");
    var video = overlay.querySelector("video");
    // Opening the overlay is a deliberate click (user gesture), so the
    // autoplay policy lets us unmute: sound is the point of the
    // fullscreen-ish live view. `muted` attribute stays in markup so
    // nothing autoplays with sound on page load.
    video.muted = false;
    liveZoom = HNVR.zoompan(video);
    var statusEl = overlay.querySelector(".live-overlay-status-text");
    var ledEl = overlay.querySelector(".led");
    var slugEl = overlay.querySelector(".live-overlay-head .slug");
    if (slugEl) slugEl.textContent = slug;

    /* PTZ drawer: clone the camera's template into the overlay slot
       (template only exists for ptz_enabled cameras AND logged-in
       users — the server omits them otherwise, so tpl is also the
       toggle-visibility signal). */
    var ptzSlot = overlay.querySelector(".live-overlay-ptz");
    var ptzToggle = overlay.querySelector(".live-overlay-head [data-ptz-toggle]");
    var tpl = document.querySelector('template[data-ptz-for="' + slug + '"]');
    if (ptzSlot) {
      ptzSlot.innerHTML = "";
      if (tpl && camId && HNVR.ptz) {
        ptzSlot.appendChild(tpl.content.cloneNode(true));
        livePtz = HNVR.ptz(camId, ptzSlot);
      }
    }
    if (ptzToggle) ptzToggle.hidden = !tpl;

    overlay.hidden = false;
    requestAnimationFrame(function () {
      overlay.classList.add("is-open");
    });

    // FLIP: animate the panel from the card's thumbnail rect.
    var panel = overlay.querySelector(".live-overlay-panel");
    var thumb = card.querySelector(".cam-live") || card;
    var first = thumb.getBoundingClientRect();
    var last = panel.getBoundingClientRect();
    var dx = first.left + first.width / 2 - (last.left + last.width / 2);
    var dy = first.top + first.height / 2 - (last.top + last.height / 2);
    var sx = first.width / Math.max(last.width, 1);
    var sy = first.height / Math.max(last.height, 1);
    if (panel.animate)
      panel.animate(
        [
          { transform: "translate(" + dx + "px," + dy + "px) scale(" + sx + "," + sy + ")" },
          { transform: "none" },
        ],
        { duration: 300, easing: "cubic-bezier(.22,1,.36,1)" }
      );

    function setState(state) {
      if (statusEl)
        statusEl.textContent =
          state === "live"
            ? "Live"
            : state === "reconnecting"
              ? "Reconnecting…"
              : state.indexOf("error:") === 0
                ? "Error: " + state.replace(/^error:\s*/, "")
                : "Connecting…";
      if (ledEl)
        ledEl.className =
          "led " + (state === "live" ? "led-on" : state === "reconnecting" ? "led-warn" : state.indexOf("error:") === 0 ? "led-off" : "led-warn");
    }
    setState("connecting");
    liveSession = HNVR.whep(slug, video, setState);

    overlay.querySelector("[data-live-fullscreen]").onclick = function () {
      HNVR.toggleFullscreen(overlay.querySelector(".live-overlay-video"));
    };
  }
  function closeLive() {
    var overlay = document.getElementById("live-overlay");
    if (!overlay || overlay.hidden) return;
    overlay.classList.remove("is-open");
    if (liveSession) {
      liveSession.close();
      liveSession = null;
    }
    if (livePtz) {
      livePtz.close();
      livePtz = null;
    }
    if (liveZoom) {
      liveZoom.reset();
      liveZoom = null;
    }
    var ptzSlot = overlay.querySelector(".live-overlay-ptz");
    if (ptzSlot) ptzSlot.innerHTML = "";
    var ptzToggle = overlay.querySelector(".live-overlay-head [data-ptz-toggle]");
    if (ptzToggle) ptzToggle.hidden = true;
    var video = overlay.querySelector("video");
    if (video) video.srcObject = null;
    setTimeout(function () {
      overlay.hidden = true;
    }, 260);
  }
  function initLiveOverlay() {
    document.querySelectorAll(".cam-card[data-slug]").forEach(function (card) {
      card.addEventListener("click", function (e) {
        if (e.target.closest("a, button, input, form")) return;
        openLive(card);
      });
    });
    var overlay = document.getElementById("live-overlay");
    if (!overlay) return;
    overlay.querySelectorAll("[data-live-close]").forEach(function (el) {
      el.addEventListener("click", closeLive);
    });
    overlay.addEventListener("click", function (e) {
      if (e.target === overlay) closeLive();
    });
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape") closeLive();
    });
  }

  /* ── Event thumbnail lightbox ───────────────────────────────── */
  function initLightbox() {
    var lb = document.getElementById("lightbox");
    if (!lb) return;
    var img = lb.querySelector("img");
    var cap = lb.querySelector("figcaption");
    document.querySelectorAll(".ev-thumb").forEach(function (thumb) {
      thumb.addEventListener("click", function (e) {
        e.stopPropagation();
        var src = thumb.getAttribute("data-full") || (thumb.querySelector("img") || {}).src;
        if (!src) return;
        img.src = src;
        if (cap) cap.textContent = thumb.getAttribute("data-caption") || "";
        lb.hidden = false;
        requestAnimationFrame(function () {
          lb.classList.add("is-open");
        });
      });
    });
    function close() {
      lb.classList.remove("is-open");
      setTimeout(function () {
        lb.hidden = true;
        img.src = "";
      }, 230);
    }
    lb.addEventListener("click", close);
    document.addEventListener("keydown", function (e) {
      if (e.key === "Escape" && !lb.hidden) close();
    });
  }

  /* ── Timezones ────────────────────────────────────────────────
   * Times render server-side in UTC inside [data-utc-ts] spans; we
   * rewrite them to the viewer's zone: the logged-in user's profile
   * timezone (body[data-user-tz]) or the browser's zone when unset.
   */
  function browserTz() {
    try {
      return Intl.DateTimeFormat().resolvedOptions().timeZone || "UTC";
    } catch (e) {
      return "UTC";
    }
  }
  HNVR.viewerTz = function () {
    var t = document.body && document.body.getAttribute("data-user-tz");
    return t || browserTz();
  };
  function tzLabel() {
    var tz = HNVR.viewerTz();
    if (tz === "UTC") return "UTC";
    try {
      // Short zone abbreviation (e.g. "MSK", "CEST") when the ICU
      // data has one; otherwise the IANA name.
      var parts = new Intl.DateTimeFormat("en-US", {
        timeZone: tz,
        timeZoneName: "short",
      }).formatToParts(new Date());
      var named = parts.filter(function (p) {
        return p.type === "timeZoneName";
      })[0];
      // Some ICU builds (e.g. headless chromium) have no named
      // abbreviations and return "GMT+2" — prefer the IANA name then.
      if (named && !/^[+-]/.test(named.value) && !/^GMT/.test(named.value))
        return named.value;
    } catch (e) {}
    return tz;
  }
  HNVR.formatTs = function (iso, mode) {
    var d = new Date(iso);
    if (isNaN(d)) return iso;
    var opts = {
      timeZone: HNVR.viewerTz(),
      hour12: false,
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    };
    if (mode !== "time") {
      opts.year = "numeric";
      opts.month = "2-digit";
      opts.day = "2-digit";
    }
    try {
      // sv-SE renders ISO-ordered "YYYY-MM-DD HH:mm:ss".
      return new Intl.DateTimeFormat("sv-SE", opts).format(d);
    } catch (e) {
      return d.toISOString().replace("T", " ").slice(0, 19);
    }
  };
  HNVR.applyTz = function (root) {
    (root || document)
      .querySelectorAll("[data-utc-ts]")
      .forEach(function (el) {
        el.textContent = HNVR.formatTs(
          el.getAttribute("data-utc-ts"),
          el.getAttribute("data-utc-ts-fmt")
        );
        el.setAttribute("title", HNVR.viewerTz());
      });
  };

  /* datetime-local filter inputs: server parses the submitted value as
   * UTC; display/edit in the viewer's zone instead. On load we convert
   * the server-rendered UTC value to local; on submit we convert back. */
  function initTzDateInputs() {
    var inputs = Array.prototype.slice.call(
      document.querySelectorAll("input[data-tz-dt]")
    );
    if (!inputs.length) return;
    function pad(n) {
      return (n < 10 ? "0" : "") + n;
    }
    function utcToLocal(v) {
      var d = new Date(v + (v.length === 16 ? ":00Z" : "Z"));
      if (isNaN(d)) return v;
      var p = new Intl.DateTimeFormat("sv-SE", {
        timeZone: HNVR.viewerTz(),
        hour12: false,
        year: "numeric",
        month: "2-digit",
        day: "2-digit",
        hour: "2-digit",
        minute: "2-digit",
      }).format(d);
      return p.replace(" ", "T");
    }
    function localToUtc(v) {
      var m = v.match(/^(\d+)-(\d+)-(\d+)T(\d+):(\d+)/);
      if (!m) return v;
      // Interpret the wall-clock fields in the viewer's zone by probing
      // the offset for that instant.
      var guess = Date.UTC(+m[1], +m[2] - 1, +m[3], +m[4], +m[5]);
      function offsetAt(ms) {
        var s = new Intl.DateTimeFormat("sv-SE", {
          timeZone: HNVR.viewerTz(),
          hour12: false,
          year: "numeric",
          month: "2-digit",
          day: "2-digit",
          hour: "2-digit",
          minute: "2-digit",
        }).format(new Date(ms));
        var p = s.match(/(\d+)-(\d+)-(\d+) (\d+):(\d+)/);
        return Date.UTC(+p[1], +p[2] - 1, +p[3], +p[4], +p[5]) - ms;
      }
      var off = offsetAt(guess);
      var utc = guess - off;
      // One correction pass for DST-boundary probes.
      var off2 = offsetAt(utc);
      if (off2 !== off) utc = guess - off2;
      var d = new Date(utc);
      return (
        d.getUTCFullYear() +
        "-" +
        pad(d.getUTCMonth() + 1) +
        "-" +
        pad(d.getUTCDate()) +
        "T" +
        pad(d.getUTCHours()) +
        ":" +
        pad(d.getUTCMinutes())
      );
    }
    inputs.forEach(function (inp) {
      if (inp.value) inp.value = utcToLocal(inp.value);
    });
    inputs.forEach(function (inp) {
      var form = inp.closest("form");
      if (!form || form.__tzDtWired) return;
      form.__tzDtWired = true;
      form.addEventListener("submit", function () {
        form.querySelectorAll("input[data-tz-dt]").forEach(function (i) {
          if (i.value) i.value = localToUtc(i.value);
        });
      });
    });
  }

  /* ── Profile page: timezone dropdown ────────────────────────── */
  function initProfileTz() {
    var sel = document.querySelector("select[data-tz-select]");
    document.querySelectorAll("[data-tz-browser]").forEach(function (el) {
      el.textContent = browserTz();
    });
    if (!sel) return;
    var current = sel.value;
    var zones = [];
    try {
      zones = Intl.supportedValuesOf("timeZone");
    } catch (e) {}
    zones.forEach(function (z) {
      if (z === current) return;
      var opt = document.createElement("option");
      opt.value = z;
      opt.textContent = z;
      if (z === browserTz()) opt.textContent = z + " (browser)";
      sel.appendChild(opt);
    });
    document.querySelectorAll("[data-tz-use-browser]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        var tz = browserTz();
        var found = Array.prototype.slice.call(sel.options).some(function (o) {
          if (o.value === tz) {
            o.selected = true;
            return true;
          }
          return false;
        });
        if (!found) {
          var opt = document.createElement("option");
          opt.value = tz;
          opt.textContent = tz;
          opt.selected = true;
          sel.appendChild(opt);
        }
      });
    });
  }
  /* ── Topbar clock (viewer's timezone) ───────────────────────── */
  function initClock() {
    var el = document.querySelector(".topbar .clock");
    if (!el) return;
    function tick() {
      el.textContent = HNVR.formatTs(new Date().toISOString()) + " " + tzLabel();
    }
    tick();
    setInterval(tick, 1000);
  }

  function init() {
    initSidebar();
    initDropdowns();
    document.querySelectorAll("[data-theme-option]").forEach(function (el) {
      el.addEventListener("click", function () {
        HNVR.setTheme(el.getAttribute("data-theme-option"));
      });
    });
    // Floating on-video fullscreen buttons (wrapper fullscreen — see
    // HNVR.toggleFullscreen).
    document.querySelectorAll("[data-zoompan-fs]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        HNVR.toggleFullscreen(btn.closest(".video-frame, .live-overlay-video, .tl-player-body"));
      });
    });
    // PTZ drawer slide toggle (ShowLive page + dashboard overlay).
    // Scoped to the enclosing overlay when the clicked button lives in
    // one so the page-level and overlay drawers never cross-talk.
    document.addEventListener("click", function (e) {
      var btn = e.target.closest("[data-ptz-toggle]");
      if (!btn) return;
      var scope = btn.closest(".live-overlay") || document;
      var drawer = scope.querySelector(".ptz-drawer");
      if (drawer) drawer.classList.toggle("open");
    });
    initCollapsibles();
    initSortableTables();
    initTableFilters();
    initRowLinks();
    // Destructive forms: <form data-confirm="..."> gets a confirm()
    // gate before submit (camera delete, timeline purge, …).
    document.addEventListener("submit", function (e) {
      var f = e.target;
      if (!f.getAttribute) return;
      var msg = f.getAttribute("data-confirm");
      if (msg && !window.confirm(msg)) e.preventDefault();
    });
    initLiveFrames();
    initFitGrids();
    initLiveOverlay();
    initLightbox();
    initClock();
    initTzDateInputs();
    initProfileTz();
    HNVR.applyTz(document);
    HNVR.setTheme(
      document.documentElement.getAttribute("data-theme") || "midnight"
    );
  }

  /* ── fMP4 box helpers (archive playback surgery) ─────────────── */
  function fmp4typ(b, o) {
    return String.fromCharCode(b[o + 4], b[o + 5], b[o + 6], b[o + 7]);
  }
  function fmp4EachBox(dv, b, start, end, cb) {
    var i = start;
    while (i + 8 <= end) {
      var size = dv.getUint32(i);
      var hdr = 8;
      if (size === 1) {
        size = Number(dv.getBigUint64(i + 8));
        hdr = 16;
      } else if (size === 0) size = end - i;
      if (size < hdr || i + size > end) break;
      cb(i, size, hdr);
      i += size;
    }
  }
  function fmp4Find(dv, b, start, end, want) {
    var hit = null;
    fmp4EachBox(dv, b, start, end, function (i, size, hdr) {
      if (!hit && fmp4typ(b, i) === want) hit = { off: i, size: size, hdr: hdr };
    });
    return hit;
  }
  /* init moov → per-track {id, ts, handler}; video track singled out. */
  function fmp4Tracks(dv, b) {
    var moov = fmp4Find(dv, b, 0, b.length, "moov");
    if (!moov) return null;
    var tracks = [];
    fmp4EachBox(dv, b, moov.off + moov.hdr, moov.off + moov.size, function (ti, tsize, thdr) {
      if (fmp4typ(b, ti) !== "trak") return;
      var trackId = 0,
        ts = 0,
        handler = "";
      var tkhd = fmp4Find(dv, b, ti + thdr, ti + tsize, "tkhd");
      if (tkhd) trackId = dv.getUint32(tkhd.off + tkhd.hdr + (b[tkhd.off + tkhd.hdr] === 1 ? 20 : 12));
      var mdia = fmp4Find(dv, b, ti + thdr, ti + tsize, "mdia");
      if (mdia) {
        var mdhd = fmp4Find(dv, b, mdia.off + mdia.hdr, mdia.off + mdia.size, "mdhd");
        if (mdhd) ts = dv.getUint32(mdhd.off + mdhd.hdr + (b[mdhd.off + mdhd.hdr] === 1 ? 20 : 12));
        var hdlr = fmp4Find(dv, b, mdia.off + mdia.hdr, mdia.off + mdia.size, "hdlr");
        if (hdlr)
          handler = String.fromCharCode(
            b[hdlr.off + hdlr.hdr + 8],
            b[hdlr.off + hdlr.hdr + 9],
            b[hdlr.off + hdlr.hdr + 10],
            b[hdlr.off + hdlr.hdr + 11]
          );
      }
      if (trackId && ts) tracks.push({ id: trackId, ts: ts, handler: handler });
    });
    return tracks.length ? tracks : null;
  }
  /* moof → per-traf {trackId, tfdtOff, ver, tfdt, trun} */
  function fmp4Fragment(dv, b) {
    var moof = fmp4Find(dv, b, 0, b.length, "moof");
    var mdat = fmp4Find(dv, b, 0, b.length, "mdat");
    if (!moof) return null;
    var trafs = [];
    fmp4EachBox(dv, b, moof.off + moof.hdr, moof.off + moof.size, function (ti, tsize, thdr) {
      if (fmp4typ(b, ti) !== "traf") return;
      var tfhd = fmp4Find(dv, b, ti + thdr, ti + tsize, "tfhd");
      if (!tfhd) return;
      var trackId = dv.getUint32(tfhd.off + tfhd.hdr + 4);
      var tfdt = fmp4Find(dv, b, ti + thdr, ti + tsize, "tfdt");
      var trun = fmp4Find(dv, b, ti + thdr, ti + tsize, "trun");
      var val = null,
        ver = 0,
        tfdtOff = 0;
      if (tfdt) {
        ver = b[tfdt.off + tfdt.hdr];
        tfdtOff = tfdt.off + tfdt.hdr + 4;
        val = ver === 1 ? Number(dv.getBigUint64(tfdtOff)) : dv.getUint32(tfdtOff);
      }
      trafs.push({
        trackId: trackId,
        trafOff: ti,
        trafSize: tsize,
        tfdtOff: tfdtOff,
        ver: ver,
        tfdt: val,
        trun: trun ? { off: trun.off, hdr: trun.hdr } : null,
      });
    });
    return { moof: moof, mdat: mdat, trafs: trafs };
  }
  /* trun → {dataOffset, bytes, span}: sample byte total and duration
   * sum. Our layout: one trun per traf, single data_offset, per-sample
   * duration+size entries. */
  function fmp4Trun(dv, b, off, hdr) {
    var p = off + hdr;
    var flags = (b[p + 1] << 16) | (b[p + 2] << 8) | b[p + 3];
    var count = dv.getUint32(p + 4);
    p += 8;
    var dataOffset = null;
    if (flags & 0x1) {
      dataOffset = dv.getInt32(p);
      p += 4;
    }
    if (flags & 0x4) p += 4;
    var bytes = 0,
      span = 0;
    for (var s = 0; s < count; s++) {
      if (flags & 0x100) {
        span += dv.getUint32(p);
        p += 4;
      }
      if (flags & 0x200) {
        bytes += dv.getUint32(p);
        p += 4;
      }
      if (flags & 0x400) p += 4;
      if (flags & 0x800) p += 4;
    }
    return { dataOffset: dataOffset, bytes: bytes, span: span };
  }

  /* ── fMP4 legacy-audio loader for hls.js ───────────────────────
   * Pre-v0.15 recordings carry a malformed audio track (camera G.711
   * sampled at 16 kHz but clocked at 8 kHz): audio PTS runs ~2x video
   * PTS (or jitters wildly), which makes per-fragment MSE appends
   * present only the first video frame (black/frozen player) while
   * hls.js storms the whole playlist. This hls.js fLoader:
   *  1. rewrites every non-video traf's tfdt in each moof to the video
   *     traf's tfdt (rescaled by track timescale) — no-op (±1 tick) on
   *     fixed recordings;
   *  2. with {stripAudio: true} (legacy window, detected up-front by
   *     HNVR.fmp4RewritePlaylist), rebuilds each fragment WITHOUT the
   *     audio traf and its mdat bytes (sizes + video trun data_offset
   *     fixed; the init passed to hls.js is likewise audio-less) —
   *     legacy recordings play video-only, smooth; the audio on them
   *     was slowed garbage anyway. */
  HNVR.fmp4PatchLoader = function (Hls, opts) {
    var stripAudio = !!(opts && opts.stripAudio);
    var trackTs = {};
    var videoTrackId = 0;
    var videoTs = 90000;

    function parseInit(dv, b) {
      var tracks = fmp4Tracks(dv, b);
      if (!tracks) return;
      tracks.forEach(function (t) {
        trackTs[t.id] = t.ts;
        if (t.handler === "vide") {
          videoTrackId = t.id;
          videoTs = t.ts || videoTs;
        }
      });
    }
    function patchTfdts(dv, trafs) {
      if (trafs.length < 2 || !videoTrackId) return;
      var vt = null;
      trafs.forEach(function (t) {
        if (t.trackId === videoTrackId) vt = t.tfdt;
      });
      if (vt === null) return;
      trafs.forEach(function (t) {
        if (t.trackId === videoTrackId || t.tfdt === null) return;
        var ts = trackTs[t.trackId];
        if (!ts) return;
        var aligned = Math.round((vt * ts) / videoTs);
        if (t.ver === 1) dv.setBigUint64(t.tfdtOff, BigInt(aligned));
        else dv.setUint32(t.tfdtOff, aligned >>> 0);
      });
    }
    /* Rebuild the fragment without the audio traf and its mdat bytes,
     * fixing moof/mdat sizes and the video trun data_offset (relative
     * to moof start — the moof shrinks, and the audio block may precede
     * the video block). */
    function stripFragment(dv, b, frag) {
      var audio = null,
        videoTraf = null;
      frag.trafs.forEach(function (t) {
        if (t.trackId === videoTrackId) videoTraf = t;
        else if (!audio) audio = t;
      });
      if (!audio || !videoTraf || !videoTraf.trun || !audio.trun || !frag.mdat) return b;
      var vTrun = fmp4Trun(dv, b, videoTraf.trun.off, videoTraf.trun.hdr);
      var aTrun = fmp4Trun(dv, b, audio.trun.off, audio.trun.hdr);
      if (vTrun.dataOffset === null || aTrun.dataOffset === null) return b;
      var moofShrink = audio.trafSize;
      var aStart = frag.moof.off + aTrun.dataOffset;
      var vDataDelta = moofShrink + (aStart < frag.moof.off + vTrun.dataOffset ? aTrun.bytes : 0);
      var newMoofSize = frag.moof.size - moofShrink;
      var newMdatSize = frag.mdat.size - aTrun.bytes;
      var out = new Uint8Array(b.length - moofShrink - aTrun.bytes);
      var odv = new DataView(out.buffer);
      var o = 0;
      out.set(b.subarray(frag.moof.off, frag.moof.off + 4), o);
      odv.setUint32(o, newMoofSize);
      o += 4;
      out.set(b.subarray(frag.moof.off + 4, frag.moof.off + frag.moof.hdr), o);
      o += frag.moof.hdr - 4;
      fmp4EachBox(dv, b, frag.moof.off + frag.moof.hdr, frag.moof.off + frag.moof.size, function (bi, bsize) {
        if (bi === audio.trafOff) return;
        var chunk = new Uint8Array(b.subarray(bi, bi + bsize));
        if (bi === videoTraf.trafOff && videoTraf.trun) {
          var cvd = new DataView(chunk.buffer);
          cvd.setInt32(videoTraf.trun.off + videoTraf.trun.hdr + 8 - bi, vTrun.dataOffset - vDataDelta);
        }
        out.set(chunk, o);
        o += bsize;
      });
      out.set(b.subarray(frag.mdat.off, frag.mdat.off + 4), o);
      odv.setUint32(o, newMdatSize);
      o += 4;
      out.set(b.subarray(frag.mdat.off + 4, frag.mdat.off + frag.mdat.hdr), o);
      o += frag.mdat.hdr - 4;
      var payloadStart = frag.mdat.off + frag.mdat.hdr;
      var mdatEnd = frag.mdat.off + frag.mdat.size;
      var aEnd = aStart + aTrun.bytes;
      if (aEnd <= payloadStart || aStart >= mdatEnd) {
        out.set(b.subarray(payloadStart, mdatEnd), o);
        o += mdatEnd - payloadStart;
      } else {
        out.set(b.subarray(payloadStart, aStart), o);
        o += aStart - payloadStart;
        out.set(b.subarray(aEnd, mdatEnd), o);
        o += mdatEnd - aEnd;
      }
      return out.slice(0, o);
    }
    return class TfdtPatchLoader extends Hls.DefaultConfig.loader {
      load(context, config, callbacks) {
        return super.load(context, config, {
          onSuccess: function (resp, stats, ctx, xhr) {
            try {
              var data = resp && resp.data;
              if (data && data.byteLength > 8) {
                var b = new Uint8Array(data);
                var dv = new DataView(data);
                if (fmp4Find(dv, b, 0, b.length, "moov")) {
                  parseInit(dv, b);
                } else {
                  var frag = fmp4Fragment(dv, b);
                  if (frag && frag.trafs.length) {
                    if (stripAudio) {
                      var stripped = stripFragment(dv, b, frag);
                      if (stripped !== b) resp.data = stripped.buffer;
                    } else {
                      patchTfdts(dv, frag.trafs);
                    }
                  }
                }
              }
            } catch (e) {}
            callbacks.onSuccess(resp, stats, ctx, xhr);
          },
          onError: callbacks.onError,
          onTimeout: callbacks.onTimeout,
          onProgress: callbacks.onProgress,
        });
      }
    };
  };

  /* ── Archive playlist repair + legacy detection ────────────────
   * Server playlists declare EXTINF from DB wall-clock segment times,
   * which drift from real media durations (irregular keyframe-cut
    * fragment lengths); hls.js positions fragments by cumulative EXTINF
    * so the timeline accumulates holes and overlaps (stalls, bufferFull
    * churn). This range-GETs every fragment's moof head, diffs video
    * tfdts for TRUE durations, and detects legacy audio skew as an
    * aggregate audio-time vs video-time slope far from 1 (see the
    * decision block below for why per-boundary ratios are not enough).
    * Legacy windows additionally get the init moov
    * stripped of its audio trak (+trex) so playback is video-only from
    * the first append — mid-playback audio loss would stall A/V sync.
    * Resolves {text, stripAudio}; probe/init failures fall back to the
    * original playlist text. Fragment/init URLs in the playlist are
    * absolute presigned S3, so the result is fed to hls.js via Blob URL. */
  HNVR.fmp4RewritePlaylist = function (m3u8Text) {
    function fetchRange(url, bytes) {
      return fetch(url, { headers: { Range: "bytes=0-" + bytes } }).then(function (r) {
        if (!r.ok && r.status !== 206) throw new Error("probe " + r.status);
        return r.arrayBuffer();
      });
    }
    function stripInit(buf, audioTrackId) {
      var b = new Uint8Array(buf);
      var dv = new DataView(buf);
      var moov = fmp4Find(dv, b, 0, b.length, "moov");
      if (!moov) return buf;
      var parts = [];
      var newSize = moov.size;
      fmp4EachBox(dv, b, moov.off + moov.hdr, moov.off + moov.size, function (ci, csize, chdr) {
        var t = fmp4typ(b, ci);
        if (t === "trak") {
          var tkhd = fmp4Find(dv, b, ci + chdr, ci + csize, "tkhd");
          var id = tkhd ? dv.getUint32(tkhd.off + tkhd.hdr + (b[tkhd.off + tkhd.hdr] === 1 ? 20 : 12)) : 0;
          if (id === audioTrackId) {
            newSize -= csize;
            return;
          }
          parts.push({ off: ci, size: csize });
        } else if (t === "mvex") {
          var keep = [];
          var mvexNew = csize;
          fmp4EachBox(dv, b, ci + chdr, ci + csize, function (ti, tsize, thdr) {
            if (fmp4typ(b, ti) === "trex" && dv.getUint32(ti + thdr + 4) === audioTrackId) {
              mvexNew -= tsize;
              newSize -= tsize;
              return;
            }
            keep.push({ off: ti, size: tsize });
          });
          parts.push({ mvex: ci, hdr: chdr, keep: keep, newSize: mvexNew });
        } else parts.push({ off: ci, size: csize });
      });
      if (newSize === moov.size) return buf;
      var out = new Uint8Array(b.length - (moov.size - newSize));
      var odv = new DataView(out.buffer);
      out.set(b.subarray(0, moov.off));
      odv.setUint32(moov.off, newSize);
      var o = moov.off + 4;
      out.set(b.subarray(moov.off + 4, moov.off + moov.hdr), o);
      o += moov.hdr - 4;
      parts.forEach(function (p) {
        if (p.mvex !== undefined) {
          out.set(b.subarray(p.mvex, p.mvex + p.hdr), o);
          odv.setUint32(o, p.newSize);
          o += p.hdr;
          p.keep.forEach(function (k) {
            out.set(b.subarray(k.off, k.off + k.size), o);
            o += k.size;
          });
        } else {
          out.set(b.subarray(p.off, p.off + p.size), o);
          o += p.size;
        }
      });
      return out.buffer;
    }
    var lines = m3u8Text.split("\n");
    var initUrl = null;
    var entries = [];
    var mapRe = /EXT-X-MAP:URI="([^"]+)"/;
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(mapRe);
      if (m) initUrl = m[1];
      var e = lines[i].match(/^#EXTINF:([\d.]+)/);
      if (e && i + 1 < lines.length && /^https?:/.test(lines[i + 1])) {
        entries.push({ lineIndex: i, url: lines[i + 1], origDur: parseFloat(e[1]) });
      }
    }
    if (!initUrl || !entries.length) return Promise.resolve({ text: m3u8Text, stripAudio: false });
    return fetch(initUrl)
      .then(function (r) {
        return r.arrayBuffer();
      })
      .then(function (initBuf) {
        var tracks = fmp4Tracks(new DataView(initBuf), new Uint8Array(initBuf));
        if (!tracks) return { text: m3u8Text, stripAudio: false };
        var video = null,
          audio = null;
        tracks.forEach(function (t) {
          if (t.handler === "vide") video = t;
          else if (!audio) audio = t;
        });
        if (!video) return { text: m3u8Text, stripAudio: false };
        var probes = new Array(entries.length);
        var next = 0;
        function worker() {
          if (next >= entries.length) return Promise.resolve();
          var idx = next++;
          return fetchRange(entries[idx].url, 8191)
            .then(function (buf) {
              var b = new Uint8Array(buf);
              var dv = new DataView(buf);
              var frag = fmp4Fragment(dv, b);
              var rec = {};
              if (frag)
                frag.trafs.forEach(function (t) {
                  if (t.tfdt === null || !t.trun) return;
                  var tr = fmp4Trun(dv, b, t.trun.off, t.trun.hdr);
                  rec[t.trackId] = { tfdt: t.tfdt, span: tr.span };
                });
              probes[idx] = rec;
            })
            .catch(function () {
              probes[idx] = null;
            })
            .then(worker);
        }
        var pool = [];
        for (var w = 0; w < 8; w++) pool.push(worker());
        return Promise.all(pool).then(function () {
          var ts = video.ts;
          var durations = entries.map(function (en, k) {
            var p = probes[k] && probes[k][video.id];
            var nx = probes[k + 1] && probes[k + 1][video.id];
            if (p && nx && nx.tfdt > p.tfdt) return (nx.tfdt - p.tfdt) / ts;
            if (p && p.span > 0) return p.span / ts;
            return en.origDur;
          });
          entries.forEach(function (en, k) {
            lines[en.lineIndex] = "#EXTINF:" + durations[k].toFixed(3) + ",";
          });
          var legacy = false;
          if (audio) {
            /* Legacy-skew decision by AGGREGATE slope, not per-boundary
             * hits. Pre-v0.15 windows run audio at a consistent ~0.5x
             * video rate (G.711 sampled 16k, clocked 8k) — the slope
             * over the whole window is far from 1. Post-retag (v0.17)
             * windows play audio at the true rate but their per-
             * boundary ratios are NOISY (cameras emit non-monotonic
             * audio DTS; ffmpeg bumps them), which used to trip the
             * old 2-consecutive-out-of-band rule and strip healthy
             * audio. Sum dA/dV across all usable boundaries: jitter
             * cancels, a systematic skew does not. */
            var sumDV = 0,
              sumDA = 0,
              usable = 0;
            for (var k = 1; k < entries.length; k++) {
              var pv = probes[k - 1] && probes[k - 1][video.id];
              var cv = probes[k] && probes[k][video.id];
              var pa = probes[k - 1] && probes[k - 1][audio.id];
              var ca = probes[k] && probes[k][audio.id];
              if (!pv || !cv || !pa || !ca) continue;
              var dV = (cv.tfdt - pv.tfdt) / video.ts;
              var dA = (ca.tfdt - pa.tfdt) / audio.ts;
              if (dV <= 0.02 || dA < 0) continue;
              sumDV += dV;
              sumDA += dA;
              usable++;
            }
            if (usable >= 4 && sumDV > 0) {
              var slope = sumDA / sumDV;
              legacy = slope < 0.75 || slope > 1.33;
            }
          }
          if (legacy) {
            var strippedInit = stripInit(initBuf, audio.id);
            var blobUrl = URL.createObjectURL(new Blob([strippedInit], { type: "video/mp4" }));
            for (var li = 0; li < lines.length; li++) {
              if (mapRe.test(lines[li])) {
                lines[li] = '#EXT-X-MAP:URI="' + blobUrl + '"';
                break;
              }
            }
          }
          return { text: lines.join("\n"), stripAudio: legacy };
        });
      })
      .catch(function () {
        return { text: m3u8Text, stripAudio: false };
      });
  };

  /* One-call archive wiring: fetch playlist → repair durations +
   * legacy detection → hls.js with the right fLoader, blob-sourced.
   * baseCfg carries the caller's buffer caps; onReady gets the hls
   * instance for event handlers. */
  HNVR.hlsArchive = function (Hls, video, src, baseCfg) {
    return fetch(src, { credentials: "same-origin" })
      .then(function (r) {
        return r.text();
      })
      .then(HNVR.fmp4RewritePlaylist)
      .catch(function () {
        return { text: null, stripAudio: false };
      })
      .then(function (res) {
        var cfg = Object.assign({}, baseCfg, {
          fLoader: HNVR.fmp4PatchLoader(Hls, { stripAudio: res.stripAudio }),
        });
        var hls = new Hls(cfg);
        hls.attachMedia(video);
        if (res.text)
          hls.loadSource(URL.createObjectURL(new Blob([res.text], { type: "application/vnd.apple.mpegurl" })));
        else hls.loadSource(src);
        return hls;
      });
  };

  if (document.readyState === "loading")
    document.addEventListener("DOMContentLoaded", init);
  else init();
})();
