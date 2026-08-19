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
  function initSidebar() {
    var shell = document.querySelector(".shell");
    if (!shell) return;
    var collapsed = false;
    try {
      collapsed = localStorage.getItem("hnvr-nav-collapsed") === "1";
    } catch (e) {}
    if (collapsed) shell.classList.add("nav-collapsed");
    document.querySelectorAll("[data-nav-toggle]").forEach(function (btn) {
      btn.addEventListener("click", function () {
        shell.classList.toggle("nav-collapsed");
        try {
          localStorage.setItem(
            "hnvr-nav-collapsed",
            shell.classList.contains("nav-collapsed") ? "1" : "0"
          );
        } catch (e) {}
      });
    });
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
   *  - zoom back out to 1x (wheel down) clears the transform; no
   *    dblclick reset — Chrome toggles fullscreen on video dblclick and
   *    we can't reliably preventDefault that UA behavior.
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

    /* PTZ panel: clone the camera's template into the overlay slot
       (template only exists for ptz_enabled cameras). */
    var ptzSlot = overlay.querySelector(".live-overlay-ptz");
    if (ptzSlot) {
      ptzSlot.innerHTML = "";
      var tpl = document.querySelector('template[data-ptz-for="' + slug + '"]');
      if (tpl && camId && HNVR.ptz) {
        ptzSlot.appendChild(tpl.content.cloneNode(true));
        livePtz = HNVR.ptz(camId, ptzSlot);
      }
    }

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
      // Fullscreen the WRAPPER, not the <video> — see HNVR.zoompan's
      // fullscreenchange comment.
      var frame = overlay.querySelector(".live-overlay-video");
      if (frame && frame.requestFullscreen) frame.requestFullscreen();
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

  /* ── Topbar UTC clock ───────────────────────────────────────── */
  function initClock() {
    var el = document.querySelector(".topbar .clock");
    if (!el) return;
    function tick() {
      el.textContent = new Date().toISOString().replace("T", " ").slice(0, 19) + " UTC";
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
    initCollapsibles();
    initSortableTables();
    initTableFilters();
    initRowLinks();
    initLiveFrames();
    initLiveOverlay();
    initLightbox();
    initClock();
    HNVR.setTheme(
      document.documentElement.getAttribute("data-theme") || "midnight"
    );
  }

  if (document.readyState === "loading")
    document.addEventListener("DOMContentLoaded", init);
  else init();
})();
