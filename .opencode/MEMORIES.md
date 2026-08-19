# HNVR — Project Memories

> Read this file FIRST before any work on this project. It's the fast-onboarding
> context for new sessions. Update it whenever you make non-trivial changes.

> **dblclick fullscreen + floating fs button (Aug 19 2026 — v0.8.0.3)**:
> Sergey: dblclick entered fullscreen but zoom stayed dead, and no
> fs-exit without Escape. Root cause: Chrome's UA dblclick on
> `<video controls>` fullscreens the VIDEO ELEMENT itself, bypassing
> the wrapper (hardware overlay → transform invisible). Fix: zoompan
> intercepts dblclick in capture phase at the host (stopPropagation
> before the shadow-root handler sees it) and routes to
> `HNVR.toggleFullscreen(wrapper)` — dblclick now enters AND exits
> wrapper fullscreen; bottom-48px control strip excluded. Native
> control-bar fs button stays hidden (it hardcodes video-element
> fullscreen); instead every wrapper has a floating `.zoompan-fs`
> corner button (visible on hover, wired centrally via
> `data-zoompan-fs`). NOTE: headless chromium has NO UA
> dblclick-fullscreen behavior at all — the e2e spec exercises only
> our handler; the UA interception needs desktop verification.
>
> **Zoom/pan fullscreen + overlay-close fixes (Aug 19 2026 — v0.8.0.1,
> completed v0.8.0.2)**: (0) **v0.8.0.1's capture-phase wheel fix was
> insufficient — fullscreen zoom stayed invisible.** Root cause: a
> fullscreened `<video>` ELEMENT can bypass the compositor (hardware
> overlay / direct scanout) and ignore CSS transforms entirely; the
> transform applied (visible after exiting fullscreen) but rendered
> nothing. Fix (the YouTube pattern): fullscreen the WRAPPER div
> (`.live-overlay-video` / `.video-frame`), transform the video inside
> it; native `::-webkit-media-controls-fullscreen-button` hidden so
> Chrome's own control-bar button can't take the video-element shortcut;
> archive player gained an explicit fullscreen button; zoompan re-clamps
> on fullscreenchange. (1) Wheel listener ALSO stays capture-phase:
> Chrome's fullscreen media controls consume wheel (volume scroll) in
> the shadow root with stopPropagation. (Headless Chromium reproduces
> neither behavior — software compositing — so both fullscreen paths are
> desktop-verified only; the e2e spec asserts the wrapper is the
> fullscreenElement.) (2) Pan drag ending
> on the dashboard overlay backdrop closed the player: Chrome dispatches
> the trailing click on the NEAREST COMMON ANCESTOR of press/release
> targets (= the overlay → its click-to-close). Click suppression after
> a >4px drag moved from the video element to window-level capture, with
> a 300 ms expiry (release outside the browser window produces no click
> — without expiry the next genuine click would be swallowed); drag also
> ends on document mouseleave. Test pitfall: `expect(overlay).toBeVisible()`
> races closeLive's 260 ms hide timeout (it passes while the element is
> still pre-close visible) — wait 500 ms before asserting. The backdrop
> regression spec was verified vacuous-then-real via git-stash of app.js.
>
> **Video zoom/pan + stale-CRUD-spec fix (Aug 19 2026 — v0.8.0.0)**:
> `HNVR.zoompan(video)` in app.js — wheel = zoom at cursor (1.25x
> notches, clamp [1,8], transform-origin 0 0, `translate(tx,ty) scale(z)`,
> pan clamped to frame edges), LMB drag pans (only when zoomed — at 1x
> nothing is intercepted so click-to-play still works; drags >4px swallow
> the trailing click; drags starting in the bottom 48px control strip are
> ignored). Zoom-out to 1x clears the transform — NO dblclick reset
> (Chrome toggles fullscreen on video dblclick; page JS can't reliably
> preventDefault that UA behavior). Wired into all three players:
> dashboard overlay (video now wrapped in `.live-overlay-video` clip div —
> the panel is overflow-y:auto for PTZ, transforms would otherwise spill
> into scrollable overflow), /ShowLive, archive player; overlay close
> resets the view. e2e `zoompan.spec.ts`. **Found while at it**:
> cameras-crud spec was stale since v0.5.2.0 (still filled the dropped
> `port` input) AND /NewCamera was broken for real users —
> `newRecord` defaults analysisFps to 0 which violates the input's
> `min="1"`, so HTML5 constraint validation silently blocked EVERY
> create submit (no POST ever reaches the server; IHP logs completed
> requests only, so nothing in the log either). Fix: NewCameraAction
> sets analysisFps=5 (design default). Full suite: 29 passed + 2
> conditional skips.
>
> Architecture (follows design 01/05/06 with noted deviations):
>   * `Hnvr.Core.Ptz` — pure wire types: PtzCommand (sum, strict
>     decode, `commandName`/`commandArgs`), PtzCommandMsg envelope
>     (command+args+source+user_id+duration_ms), PtzReply
>     (request/reply), PtzState + `stateAfter`, PtzStatusMsg,
>     PtzAuditRecord. Wire `source` values match the ptz_source PG
>     enum labels exactly (insert with `?::ptz_source` cast).
>   * `Hnvr.Onvif.Client` — PTZ ops on the PTZ XAddr with ns "tptz"
>     (envelope gained xmlns:tptz; SOAPAction ns map: tptz→ver20/ptz,
>     tds→ver10/device, tr2→ver20/media, else ver10/media).
>     `discoverPtzXAddr` (Nothing = no PTZ service), `getProfileTokens`
>     (trt GetProfiles + tr2 fallback), move/stop/absolute/goto/
>     setPreset (returns camera token)/removePreset/getPresets/
>     getStatus (xsi:nil → Nothing). Pure parsers fixture-tested
>     (7 new fixtures from live 196/197/198 incl. capabilities + nil
>     status + 255-slot preset list).
>   * `Hnvr.Ptz.Onvif.OnvifPtz` — resolved endpoint record (mgr, creds,
>     XAddr, profile token) + thin Either-returning ops. **The design's
>     `PtzDriver` typeclass was dropped** (no error channel; codebase
>     seam pattern is records of IO actions, cf. Metrics).
>   * `Hnvr.Ptz.Controller` — per-camera command loop + 1 s idle
>     ticker; subscribes hnvr.commands.ptz.<slug>, executes, replies on
>     replyTo, publishes status (hnvr.ptz.status.<slug>) + audit record
>     (hnvr.ptz.audit) after EVERY command; idle timeout → go_home
>     (home preset, else absolute origin) with source idle_timeout.
>   * Lifecycle: `CaptureSupervisor` gained csPtz handles — startCamera
>     calls maybeStartPtz (resolveOnvifPtz discovery; failure logs +
>     skips, capture unaffected), stopCamera cancels both asyncs.
>   * Snapshot: `CameraSnapshot.csPtz :: Maybe PtzSnapshot` (plaintext
>     password — same exposure class as csRtspUrl). Hand-written
>     FromJSON with `.:?` so new nodes tolerate pre-Phase-5 leaders.
>     `projectCamera`/`projectCameraWithRules` are now IO (decrypt);
>     SnapshotResponder uses a 21-column hand-written CamRow FromRow
>     (pg-simple tuple cap, pitfall #122 class; password cols are
>     `Maybe (Binary ByteString)` — what decryptPassword takes).
>   * Web: `POST /PtzCamera?ptzCameraId=` (fire-and-forget JSON;
>     set_preset/get_presets via Bus.requestJson 8 s), presets CRUD at
>     /PtzPresets (+Goto/Home/Purge; `format=json` branches for
>     ptz.js), `ProbePtzCameraAction` (discovery + profile token fill +
>     nil-status hardware warning), live-view panel + `static/ptz.js`
>     (hold-to-move pad, preset dropdown, 1 Hz status poll from
>     /PtzStatusCamera ← PtzStatusCache subscription).
>   * Audit: `PtzAuditWriter` (leader) persists the node's audit feed
>     — rows record EXECUTION with ok/error, not publish intent.
>     `Rules.publishRuleRefresh` generalized to
>     `Hnvr.Web.CommandTypes.republishAssign` (full projection incl.
>     PTZ) — reused by HomePtzPresetAction so home-token changes reach
>     the node.
>   * Schema: migration 0011-ptz (wired into SchemaMigration);
>     cameras +ptz_enabled/ptz_profile_token/ptz_home_preset_id/
>     ptz_idle_timeout_s/ptz_viewer_control; ptz_presets; ptz_source
>     enum; ptz_audit_log (+ok/error columns over design). No
>     ptz_onvif_url/ptz creds columns (runtime discovery + camera
>     creds, same as OnvifSync's media XAddr pattern).
>   * Metrics: `hnvr_ptz_commands_total{camera,command,source}` +
>     `hnvr_ptz_command_seconds{camera}` (Metrics record gained
>     mPtzCommand/mPtzCommandSeconds — update noOpMetrics +
>     Hnvr.Web.Metrics together).
>   * Kill switches: HNVR_DISABLE_PTZSTATUSCACHE / _PTZAUDIT.
>
> **Pitfall #123 (regen.sh blanket sed)**: the pitfall-#32 PK patch
> (`nullable Mapping.encoder` → `nonNullable`) also rewrote
> cameras.ptz_home_preset_id — a LEGITIMATELY nullable forward FK —
> producing `IsScalar (Maybe (Id' "ptz_presets"))` errors. regen.sh now
> re-patches the three Camera statements back to nullable after the
> blanket pass. Any future nullable `Id'` FK column hits the same trap.
> Circular FK (cameras ↔ ptz_presets) makes codegen parameterize
> `Camera' ptzHomePresetId` — expected, harmless.
>
> Live verification (196, protocol-level): continuous_move/stop/
> set_preset(token "1")/goto/remove/go_home all ok:true; 6 audit rows;
> idle return-home fired on its own 30 s after a move
> (go_home{source="idle_timeout"} 1 in /metrics). backyard row left
> ptz_enabled=true (harmless no-op hardware; demonstrates the panel).
> Playwright PTZ specs: not written (phase verified via curl; add when
> a real PTZ camera exists). Tests: 214 core + 14 ptz + 15 nats +
> 9 storage + 53 capture, pre-commit green.
> **Restart trap (hit Aug 16)**: leader-env.sh lacked the ffmpeg bin
> dir on PATH — capture/analysis workers failed with
> `createProcess: posix_spawnp: does not exist` → 5 restarts →
> FailedPermanent on all 3 cameras. Fixed; env script now exports the
> ffmpeg-full PATH. Symptom signature: all cameras offline right after
> a leader restart with ExitFailure 99 in the log.
> **Dashboard PTZ (Aug 16, same version)**: panel markup extracted to
> `Hnvr.Web.View.PtzPanel.ptzPanel` (shared by /ShowLive and the
> dashboard); `HNVR.ptz(cameraId, rootEl?)` is root-scoped and returns
> `{close()}` (stops the 1 Hz status poller). Dashboard renders a
> per-PTZ-camera `<template data-ptz-for={slug}>` (ptzPresets fetched
> in DashboardAction) + a `.live-overlay-ptz` slot in the overlay;
> app.js openLive clones the template in and binds it, closeLive
> closes + clears. cam-cards carry `data-cam-id` (PTZ endpoints key on
> the UUID, overlay opens by slug).


> **Stub/dead-field audit cleanup (Aug 16 2026 — v0.5.2.0)**: full-repo
> audit found two more user-visible lies plus a pile of dead schema.
> Fixed ALL of A+B class + C1:
>   * **A1 is_leader**: never written → every host showed WORKER.
>     HealthCache UPSERT now stamps `is_leader = (host = our HNVR_HOST)`
>     every heartbeat (startHealthCache gained the leaderHost param;
>     the write-only IORef/HealthSnapshot/readHealthCache deleted —
>     zero consumers). Config.hs reads HNVR_HOST before startHealthCache.
>   * **A2 HNVR_DB_URL**: module.nix sops fragment wrote HNVR_DB_URL but
>     all code reads DATABASE_URL — renamed the fragment key; systemd
>     EnvironmentFile overrides Environment=, so the secret wins over
>     the static cfg.databaseUrl.
>   * **Migration 0010-cleanup** (+ Schema.sql + codegen regen): drops
>     cameras.rtsp_template/rtsp_sub_template/port + hosts.display_name;
>     event_kind recreated without track_start/track_end/
>     segment_written/system (zero emitters; events_kind_idx recreated
>     plain). **0005-zone-motion.sql is now WIRED** into SchemaMigration
>     (was manual-only — fresh-deploy trap); it replays as a no-op via
>     ADD VALUE IF NOT EXISTS.
>   * **B3**: Edit/New camera forms gained enabled / record_audio /
>     use_substream_for_analysis checkboxes + analysis_fps number.
>     Booleans are explicit `set` after fill (paramOrNothing=="on",
>     Rules.hs pattern) — absent checkbox params leave IHP fill fields
>     unchanged. Also removed assignedHost/manualAssign from both fill
>     lists (no form inputs; IHP fill wipes absent Maybe params to NULL
>     — was silently unassigning cameras on every Save, masked by the
>     coordinator re-flipping).
>   * **Surfaced**: archive rows show Host badges (distinct per group)
>     + first-segment sha256 tooltip (Span gained spHostId/spSha256);
>     events table shows Host + Bbox columns + linked-segment tooltip
>     (fetchEventRows now 14 fields); drift table shows first_seen_at.
>   * **Wired**: events.payload = full CvEvent JSON;
>     events.segment_ts via insert-time scalar subquery + 60 s backfill
>     loop in EventWriter (segment rows lag rule fires by ~2 s);
>     users.last_login_at via IHP AuthSupport `beforeLogin` hook (runs
>     ONLY after password verification — confirmed in IHP source);
>     audit_log.payload written at all call sites + NEW /AuditLog
>     admin page (Web.Controller.AuditLog, latest 200, sidebar "Audit").
>     `audit` gained a `Maybe Value` payload param.
>   * **C1**: HealthReporter sends real cpu_pct (/proc/stat delta
>     between 5 s ticks), ram_bytes (/proc/meminfo used), gpu_mem_bytes
>     (nvidia-smi VRAM sum; Maybe → null on GPU-less hosts, no 0-lie).
>   * **Small**: updated_at bumped in UpdateCamera + UpdateRule actions;
>     configRules subject dropped (superseded by full-snapshot assign);
>     07-deployment.md env table rewritten to real var names
>     (HNVR_HOST/HNVR_NATS_URI/HNVR_MODEL_DIR/HNVR_TRT_CACHE_DIR/
>     DATABASE_URL/HNVR_MEDIAMTX_CONFIG_PATH); flake.nix Phase-3-stub
>     comment fixed.
>   * **Pitfall #122**: IHP `sqlExec` (hasql ToSnippetParams) caps at
>     10 params — wider INSERTs need the pg-simple one-shot-connection
>     pattern (fetchEventRows-style) with `(a,b,…) :. (c,…)` from
>     Database.PostgreSQL.Simple.Types. `:.` lives in .Types, NOT
>     .ToRow. aeson `encodePretty` is the aeson-pretty PACKAGE (not a
>     dep) — use plain encode. parseMaybe is Data.Aeson.Types.
>   * **Flaky test watch**: hnvr-cv Preprocess property "scaled dims
>     fit the target and keep aspect" failed once in a combined run,
>     then passed 4/4 standalone — rare QuickCheck edge, not from this
>     batch; revisit if it recurs.
>   * New pitfall for checkboxes: see B3 above (fill + absent Maybe =
>     NULL wipe).

> **Dead-camera UI lies fixed (Aug 16 2026 — v0.5.1.0)**: Sergey reported
> an unavailable camera still showed online + REC + last frame. Three
> root causes, three fixes. (1) REC was static HTML —
> `View/Dashboard/Index.hs`, `View/Live/Show.hs`, `View/Cameras/Show.hs`
> now render it only when the camera's resolved status is CSRecording
> (other states get STARTING/RECONNECTING/FAILED/HOST DOWN/STOPPED/
> UNASSIGNED/DISABLED badges; new `.badge-danger` in src.css). (2)
> `/debug-frame` served the stale `ahLatest` TVar with 200 forever →
> now 503s when `frameTimestamp` is >5 s old (`DebugStream.hs`
> maxFrameAgeSeconds); the app.js poller already mapped errors to the
> "no signal" placeholder. (3) Worker state was log-only →
> `captureWorkerWithStop` gained a `TVar CaptureState` param
> (transition writes Running before the blocking runOnce; WorkerSpec
> updated), CaptureSupervisor stores it in WorkerHandle (new
> `cameraStates`), HealthReporter publishes `cameras:
> [{slug,state}]` (was `[]` stub) reading the supervisor via
> `SupervisorRegistry` — **NodeMain now also writes the registry**
> (previously leader-only). Pure contract lives in
> `Hnvr.Core.CameraStatus` (CaptureStateWire text encoding,
> CameraHealth JSON, resolveCameraStatus table — 18 cabal tests);
> web-side projection `Hnvr.Web.CameraStatus.cameraStatusFor` (15 s
> heartbeat window, assigned-host row missing = host down). WHEP
> client rewritten (`app.js` HNVR.whep): real reconnect with 2→30 s
> backoff forever, 10 s connect timeout (answer but no ontrack = dead
> source behind live mediamtx path), getStats framesReceived watchdog
> (6 s stall → re-offer); new "connecting" state — ShowLive inline JS
> maps it explicitly. `get` is `IHP.HaskellSupport.get`, NOT
> IHP.ModelSupport (GHC-61689). hnvr-web sets NoFieldSelectors —
> cross-module record access needs OverloadedRecordDot + dot syntax.
> Built clean; **deploy pending: live leader still runs 0.5.0.x**.
> **Follow-ups same day**: analysis frameSourceLoop backoff cap 30s →
> 5s (`FrameSource.hs` — 1/2/4/5s; recording worker backoff
> unchanged). Live-wall badge staleness fix: badges were server-rendered
> once, so a recovered camera kept FAILED (and a freshly-dead one kept
> REC) until reload — now the single `.cam-badge-status` badge is
> JS-owned after page load: `initLiveFrames` rewrites it to REC on
> signal / NO SIGNAL on loss via change-only `setBadge` writes (an
> earlier badge-pair + CSS-swap variant rendered REC twice when a
> stale app.css lacked the swap rules — don't reintroduce it).
> **Nav toggle into the sidebar**: the ☰ button lived in the topbar —
> on mobile (≤900px off-canvas drawer) the drawer overlapped it, so
> the menu couldn't be closed. Now it's the sidebar's first child,
> absolutely positioned top-right (`src.css .sidenav .nav-toggle`);
> on mobile it peeks out at `right: -2.5rem` when the drawer is hidden
> and sits inside at `right: 0.625rem` when open.
> **GPU column fix (v0.5.1.1)**: hosts.gpu_model was always NULL —
> reporter hardcoded `"stub"` AND HealthCache's UPSERT never wrote the
> column. Now `detectGpuModel` (typed-process nvidia-smi
> `--query-gpu=name`, once at reporter start, Nothing on failure) and
> persistHostHealth lifts gpu_model out of the payload into the column.
> **exec_providers + host liveness (v0.5.1.2)**: exec_providers column
> showed the schema default ['cpu'] for every host (same unwired-stub
> class as gpu_model) — reporter now publishes the real EP list
> (`execProviderName`/`execProvidersFromEnv`, once at startup) and
> HealthCache persists it; both gpu_model + exec_providers writes are
> COALESCE-guarded so an older-build reporter can't wipe newer values.
> Host display liveness: `hostDisplayLive` (5 min window) in
> Hnvr.Web.CameraStatus, used by the dashboard host LED and /Hosts
> (LED off + DISCONNECTED badge + "N of M live" subtitle) — was:
> `Just lastHealthAt` = green forever, so yesterday's hnvr-1 row
> looked alive. Distinct from the 15 s assignment window on purpose.

> **OpenIPC FLASH DONE, low_ent (Aug 16 2026, ~11:00–11:35)**: coupler
> DVRIP flash succeeded (Ret 515; camera dark ~4 min, booted DHCP
> .184). Post-flash: coupler default SSH password is **`12345`** (not
> openipc); `firstboot` ran (overlay wiped, 8.75 MB rootfs_data);
> `sensor=imx335` auto-detected (2592×1520 native — stock's 3072×2048
> was upscaled), `totalmem=128M` (stock osmem hid it at 48M), MAC
> preserved. Config now: static **192.168.0.198**, root password
> `io27pJ3wui` (SSH + Majestic RTSP + web UI all follow /etc/shadow),
> Majestic video0 h264 2592×1520@15 4096kbit + video1 h264 640×360@15
> 1024kbit (sub-stream 5→15 fps = the CV win), jpeg snapshot, ONVIF
> enabled on **port 80** with cleartext onvif.username/password set in
> /etc/majestic.yaml. **Majestic RTSP URLs are query-style
> `/stream=0` / `/stream=1`** — path-form (/stream1 etc.) silently
> falls back to MAIN. ffprobe r_frame_rate garbage on short probes
> still applies (143/6); avg_frame_rate + encoder log are truth.
> **ONVIF auth gotcha**: Majestic challenges HTTP Digest at transport
> level; plain HTTP Basic ALSO accepted, WSSE-only = 401 →
> `Hnvr.Onvif.Client.soapCall` now sends an Authorization Basic header
> (harmless to Hik-OEM 196/197) — hnvr-ptz tests 7/7, version bumped
> **0.5.0.1**, `nix build .#hnvr-web` done; **deploy pending: restart
> the leader with the new result/ (495239 still runs 0.5.0.0)**.
> DB row updated via psql + assigned_host flipped NULL→hnvr-2 by the
> coordinator (URL changes do NOT propagate on their own — ConfigWatcher
> live-config slice still unimplemented; host flip republishes the
> snapshot and startCamera is replace-on-duplicate). Recording verified:
> ~2 frags/s, 56 segs/min steady. Analysis_fps left at 5 (Sergey can
> bump now that sub is 15fps). Pitfall **#122**: running
> `hnvr-leader --help` BOOTS the app (no --help handler) — a stray
> leader lived 21 min alongside the real one; claim guard held (no
> duplicate segments), killed manually. Always `strings | grep version`
> instead. Backup images: `/home/pion/hw-backups/low_ent-699Q3/`
> (coupler .bin, 699Q3_recovery.img, stock zip + SHA256SUMS); full
> runbook + recovery: `design_docs/11-openipc-lowent-runbook.md`.

> **low_ent ONVIF verification + Majestic fixes (Aug 16 2026 — v0.5.0.2)**:
> verified post-flash ONVIF end-to-end. Found + fixed: (1) the 0.5.0.1
> Basic-auth change computed `basicAuth` but NEVER added the header —
> Majestic 401'd everything (live leader on :18001 still runs that
> build → low_ent polls fail there until redeploy). (2) Majestic
> implements only ver20 media for configs: ver10
> `GetVideoEncoderConfigurations` faults `ter:UnknownAction` →
> `getVideoConfigs` falls back to `tr2:GetProfiles` (per-profile
> embedded tt:VideoEncoderConfiguration; fixture
> `profiles-198-openipc.xml`), and `setVideoConfig` retries as
> `tr2:SetVideoEncoderConfiguration` (accepted — verified no-op Set
> OK). soapCall now always declares xmlns:tr2 + picks the SOAPAction
> ver10/ver20 + device/media by the op namespace. (3) Majestic
> GovLength reports 50 while its options claim range 1..12 and its
> real GOP lives in majestic.yaml — gov left UNMANAGED (NULL) for
> low_ent; don't chase it. (4) Majestic has NO audio encoder configs
> over ONVIF (empty list) → audio fields silently unmanaged for
> low_ent. (5) low_ent row: mgmt_proto back to 'onvif', port 80,
> username root, RTSP query-form URLs, desired main H264
> 2592×1520@15/4096, sub H264 640×360@15/1024 — all three cameras
> "in sync", camera_drift empty, ~560 segs/10min each. (6) Per-token
> options work on Majestic but return the GLOBAL list (native
> 2592×1520 not in it; current value is prepended by the form).
> Untracked `start-shell-telnetd.bin` at repo root is a flash
> artifact — do NOT commit it.

> **OpenIPC feasibility, low_ent (Aug 16 2026)**: pulled hardware ID via
> python-dvr `get_upgrade_info()`: **`IPC_GK7205V300_G6S`** (Goke GK7205V300,
> XM IVG-G6S module, fw V5.00.R02.422699Q3, BuildTime 2024-04-19). OpenIPC
> status: GK7205V300 = stage DONE + recommended. Unpacked the official
> 000699Q3 firmware zip (tehno32.ru; `.bin` = ZIP → uImage-wrapped images,
> 64-byte header then RAW squashfs — no gzip despite uImage comp field):
> u-boot env mtdparts sum to 0x1000000 → **16 MB flash**; RAM 128 MB
> (coupler `totalmem=128M`; stock `osmem=48M` hides it); sysconfig.ko
> `sensors=` whitelist: imx335, imx307(+2l), imx327(+2l), imx206,
> sc2231/35, sc3235, sc4236, gc2053 (exact chip via ipctool at install).
> **Install runbook: `design_docs/11-openipc-lowent-runbook.md`** —
> PRIMARY PATH IS COUPLER VIA DVRIP, NO UART: exact-device image
> `000699Q3_OpenIPC_IPC_GK7205V300_G6S.bin` exists (OpenIPC/coupler
> latest release; native Hardware match, keeps stock u-boot, burns
> uImage+rootfs+env+jffs2) + stock recovery img `699Q3_recovery.img`
> (XM-DVR container for stock u-boot `run dd` TFTP recovery). Both +
> official zip archived at `/home/pion/hw-backups/low_ent-699Q3/` with
> SHA256SUMS. **Root access dead-ends (remote)**: SkipCheck InstallDesc
> Shell commands are silently DROPPED on this 2024 fw (wget/nc/telnetd
> callbacks never fire) — but **Burn works** (that's what coupler uses);
> telnetd sits on **:50119** (telnetctrl=1 was already in env; Sofia
> restart from ANY InstallDesc upload brings it up) but root pw is a
> per-device random DES hash in /mnt/mtd/Log/ns pre-hashed by XM's login
> (md5→pairwise-sum-mod62 "Dahua hash" transform, see kuku.eu.org
> xm530/part2) — xmhdipc/tlJwpbo6 etc. all rejected. UART (3.3 V,
> Ctrl-C; ⚠ 2024 XM u-boot shells may be password-locked) is the
> fallback/recovery path. Side effects left behind: telnetd:50119 open
> (root login prompt; wiped when OpenIPC lands) + camera
> Sofia-restarted once mid-session; RTSP/ONVIF verified working after.
> Open ports on 198: 80, 554, 8000, 8899(onvif), 12927, 12973, 23000,
> 34567, 50119. Post-flash HNVR TODOs are in the runbook (new RTSP URLs,
> re-probe, sub-stream fps fix).

> **ONVIF config sync (Aug 15 2026 — v0.5.0.0)**: cameras gain sparse
> desired encoder columns (NULL = unmanaged): `onvif_port`,
> `main_video_*` / `sub_video_*` (encoding/width/height/fps/
> bitrate_kbps/gov_length), `audio_*` (encoding/bitrate_kbps/
> sample_rate_khz) — migration 0008 + `camera_drift` table (UNIQUE
> camera_id+config_name+field_name). Save Changes (UpdateCameraAction)
> persists then pushes best-effort via `Hnvr.Web.OnvifSync.pushCameraConfig`
> (discover media XAddr → Get configs+options → clamp → Set only what
> differs) and immediately refreshes that camera's drift rows; push
> failure = flash error, row still saved. `Hnvr.Web.OnvifSyncer`
> (HNVR_ONVIF_POLL_SECONDS, default 300; HNVR_DISABLE_ONVIFSYNC gate)
> re-reads every managed+enabled camera and reconciles camera_drift
> (upsert bumps last_seen_at; resolved rows deleted). Badges: /Cameras
> Sync column (—/DRIFT n/SYNCED), /ShowCamera drift table.
> `Hnvr.Core.Onvif` gained `pickMainSub` (highest-res H264/H265 config
> = main; JPEG excluded) + `hostFromRtspUrl` (cameras.host is "" on all
> of Sergey's rows — host falls back to the RTSP URL authority; empty
> username = missing creds → camera skipped). Verified live vs cam-196:
> drift row appeared for bogus fps=99, auto-cleared on NULL; Save
> Changes pushed sub-stream 5→6 fps end-to-end (re-GET confirmed).
> **Pitfall #119**: cam-196 rejects a Set immediately after a previous
> Set with HTTP 400 ter:ConfigModify (encoder busy re-initializing) —
> retry after ~3 s.
> **Sync findings (Aug 15 2026, full-push session)**: all 3 cameras
> converged to desired (main native-res @15/gov15, sub @15/1024/gov15,
> drift table empty; `OnvifSyncer: <slug>: in sync` x3). Caveats:
>   * **SetAudioEncoderConfiguration is BROKEN on the 196/197
>     Hik-OEM gSOAP firmware** — even a no-op G711 set drops the
>     connection (NoResponseDataReceived), and every AAC attempt faults
>     `ter:Bitrate is not valid` although the camera's own
>     GetAudioEncoderConfigurationOptions advertises AAC@16kbps/16kHz.
>     Repeated attempts WEDGE the media service (GETs start dropping
>     too; device service stays up) — recovery needs a tds:SystemReboot
>     (works fine with WSSE digest). AAC on 196/197 must be switched in
>     the camera web UI; 198 offers G711 only (no DVRIP audio-format
>     config either). DB desired audio = G711 for all three.
>   * Pace ONVIF Sets ≥8 s apart per camera; `soapCall` now retries
>     once after a 3 s delay on transport errors.
>   * 197 main reports BitrateLimit unreliably (0 then 512) — left
>     main_video_bitrate_kbps NULL (unmanaged) for floor_2_5.
>   * XM ONVIF (198) reports Encoding=H264 while the actual RTSP
>     sub-stream is HEVC — ONVIF encoding field is decorative on XM.
>   * ffprobe r_frame_rate on short probes is garbage (250/1, 57/4);
>     trust ONVIF FrameRateLimit readback for sync checks.
>   * H265 on 197 main was silently not-applied (camera stays H264) —
>     desired reverted to H264.
> **Options-driven Edit form (Aug 15 2026, later)**: Sergey hit
> ter:ConfigModify saving low_ent — root cause: clamping against the
> UNTTOKENED Get*ConfigurationOptions merges all profiles' sections, so
> cross-stream values passed clamp and the camera rejected them.
> Get{Video,Audio}EncoderConfigurationOptions now take a per-config
> token (`Maybe Text` arg; XM 198 AND Hik-OEM 196/197 both honor it —
> main/sub resolution lists differ correctly). pushCameraConfig clamps
> per-token (falls back to untokened, then unconstrained). EditCamera
> form fetches live options (`fetchFormOptions`) and renders dropdowns:
> per-stream resolution select (splits "WxH" into hidden width/height
> inputs via inline JS), encoding/bitrate/sample-rate selects, fps/br/
> gov number inputs with min/max from ranges; free-text fallback when
> the camera is unreachable. Parsers nub the Hik-OEM duplicated
> resolution lists. **JPEG is filtered out of video encoding choices in
> BOTH the view and clampVideo** (it leaks in via the snapshot config's
> codec section on XM; pushing Encoding=JPEG to a video stream would
> break recording). Truth from per-token options: 196/197 offer H264
> only + audio G711 only — H265/AAC are NOT selectable on these
> firmwares; their AAC-in-untokened-options was a different section's
> advertisement. Sergey's H265/AAC desired values on backyard/floor_2_5
> remain as standing drift rows by his choice.
> **Codec fields split (Aug 15 2026, later)**: `codec`/`substreamCodec`/
> `substreamWidth`/`substreamHeight` are PROBE-OWNED (ffprobe via
> ProbeCameraAction) — removed from the New/Edit forms and from both
> `fill` lists. The fill removal fixes a live bug: those fields had no
> form inputs, so every Save wiped them to NULL. /Cameras table now has
> Main + Sub codec badge columns (Sub = "—" without a sub URL).
> Post-change probes: 196 h264/h264, 197 h264/h264, 198 hevc/hevc
> (probe is ground truth — XM ONVIF reports H264 while streaming HEVC).
> Sub streams are 640×360 everywhere after Sergey's dropdown saves. **Pitfall #120**: hlint misparses> OverloadedRecordDot `.id` selectors as `id` composition ("Redundant
> id" false positive) — use `cam |> get #id` instead of `cam.id`.
> **Pitfall #121**: pg-simple can't express row-constructor
> `NOT IN ?` over tuples — fetch keys and delete stale rows
> individually. Also: IHP schema parser rejects inline
> `REFERENCES` in CREATE TABLE column lists — use table-level
> `FOREIGN KEY ... REFERENCES` (extends the #115 comment rule).
> Cameras table FK columns codegen as plain UUID, not Id' — compare
> with `get #id`-unwrapped UUIDs. hnvr-ptz fixture tests must run from
> the package dir (relative test/fixtures paths) — `cabal run` from
> repo root breaks them.

> **Duplicate-capture bug + snapshot-claim guard (Aug 15 2026, late —
> v0.4.0.1)**: Sergey reported 1–2 s playback jump-backs (live +
> archive). Root cause: `hnvr-leader` embeds the full node role
> (`Config.startNodeRoles`, "leader = all of node + leader roles") AND
> a standalone `hnvr-node` was running on the same box with the same
> `HNVR_HOST=hnvr-2` → two CaptureWorkers per camera → every fragment
> uploaded twice (object keys 1–5 ms apart) → the archive playlist
> served each second of video twice = the jump-back (deterministic,
> same spot every replay). Guard shipped: `CameraSnapshotBatch` gained
> `csbClaimed`; `SnapshotResponder` denies claims for the leader's own
> host unless the request is marked `leader: true` (pure decision in
> `Hnvr.Core.HostClaim`, cabal-tested); `NodeMain` now claims BEFORE
> starting ConfigWatcher and retries every 30 s (also fixes the
> boot-race pitfall — old "rely on assign messages" path is gone).
> Deploy order: leader first — old leaders' replies lack `claimed`,
> new nodes treat that as denied (safe: idle, never double-record).
> **Retention verified working same evening**: hourly sweep deleted
> 5516 rows + 5259 S3 objects for backyard alone; row-tracked objects
> are swept correctly. "Nothing cleared from S3" was (a) orphans —
> objects without DB rows are NOT swept by design (RetentionSweeper
> header), 6318 stale 2026-08-14 orphans removed manually; (b) the dev
> disk hitting 100% → MinIO `XMinioStorageFull` → PUTs spool (1.7 GB
> backlog, drainer sheds over-cap). Side fix: vendored minio-hs
> `deleteObject` now validates HTTP status (was: silent no-op on
> 4xx/5xx — see pitfall #118).

## Identity

- **Name**: HNVR — Haskell Network Video Recorder
- **Owner**: Sergey (`omgbebebe@gmail.com`)
- **Local path**: `/home/pion/work/dev/hnvr`
- **Remote**: `gitea@192.168.0.254:omg/hnvr.git` (branch `master`)

> **Event video clips (Aug 15 2026 — v0.4.0.0, commit 1c2c6d5)**:
> separated event video store. Rules gain `clip_preroll_sec` /
> `clip_postroll_sec` / `clip_retention_hours` (NULL = clips off);
> cameras moved `retention_days` → `retention_hours` (migration 0007,
> backfilled ×24). Node-side: per-camera `Hnvr.Capture.RingBuffer`
> (pure, time-bounded, cabal-tested) fed by `Worker.handleFragment`
> via new `CameraConfig.ccClipBuffer` (CameraConfig lost its Eq/Show
> deriving — TVar); `Hnvr.Node.ClipRecorder` opens a clip on rule fire
> (snapshot buffer window `[ts-pre, ts]`), EXTENDS on subsequent fires
> (one clip per camera, deadline = last ts + postroll, retention =
> max), 1 s ticker closes + uploads `init.mp4` + fragments to
> `<slug>/clips/<YYYY-MM-DD/HH-MM-SS.mmm>/` and publishes `ClipReady`
> (cr*-prefixed fields — can't decode as CvEvent/SegmentWritten) on
> hnvr.events. EventWriter inserts `event_clips` (idempotent on
> object_prefix) + links `event_clip_events` by camera+window.
> RetentionSweeper now hours-based (`INTERVAL '1 hour'`) + sweeps
> event_clips (prefix-scoped exact delete, incl. stale tombstones 90 s
> grace). Playback: `/PlayerEventClip?clipId=` +
> `/PlaylistEventClip?playlistClipId=` (prefix LIST + presign,
> durations from key-embedded timestamps via
> `Hnvr.Core.Clip.playlistDurations`), `PurgeEventClipAction` (POST,
> admin, tombstone + async purge). /Events rows gain a "▶ clip"
> button (scalar-subquery clip_id in fetchEventRows — 11 fields
> exceeds pg-simple's 10-tuple FromRow, so a hand-written FromRow).
> Rules form gained clip fields (checkbox gates retention → NULL).
> Camera forms gained retention_hours input. Verified live: backyard
> zone_motion event → 15-fragment playable clip (ffprobe OK), playlist
> serves presigned public-endpoint URLs, purge round-trip clean.
> Playwright: 28 passed + 2 conditional skips (archive-browser
> page-param test now skips when the controller clamps to page 1 —
> pre-existing data-dependence, not a clip regression).

- **Current branch state**: Phase 0 + 1 + 2 done (code; live VM tests
  pending). Phase 3 slices 1–12 done (CV pipeline + EKG + CUDA + TRT
  with engine cache + yolov8s-640 resolution bump + the lazy-SORT
  leak fix — Aug 13 2026) + close-out (bake/accuracy tooling,
  per-camera `cameras.model_name` plumbing — Aug 14 2026). Phase 3
  done pending the longer soak run itself + final per-camera model
  call (first compare: backyard → yolov8s-640). Phase 4 (events)
  largely landed Aug 13–14 (rules engine, CvEvent pipeline,
  thumbnails, /Events UI, rules CRUD + live propagation, live feed,
  audit log). hnvr-1 stays CPU EP (pitfall #103).
  Aug 14 2026 additions: `zone_motion` rule kind (migration 0005 —
  apply manually to dev DBs: `psql $DATABASE_URL -f
  hnvr-web/migrations/0005-zone-motion.sql`); rule canvas click-coord
  fix (getBoundingClientRect) + draggable vertices; devenv MinIO now
  binds 0.0.0.0:9100 + `HNVR_S3_PUBLIC_ENDPOINT=http://192.168.0.156:9100`
  so remote browsers can fetch presigned thumbnails.
  **Web UI v2 redesign (Aug 15 2026)**: full redesign landed (not yet
  committed at write-time). CSS-vars theming (two themes: `midnight`
  dark + `daylight` light, switched via sidebar dropdown, persisted in
  localStorage `hnvr-theme`, pre-paint inline head script),
  collapsible sidebar layout (was topnav), `/static/app.js` vanilla JS
  (loaded WITHOUT defer in <head> so page-level inline scripts can use
  `HNVR.*`), sortable+filterable tables, `tr[data-href]` clickable
  rows, dashboard live wall (low-fps `/debug-frame/<uuid>` polling
  with dual-img crossfade + IntersectionObserver gating + 404 backoff),
  FLIP-animated fullscreen WHEP overlay (`HNVR.whep` shared with
  /ShowLive), Ken Burns animated event thumbnails + lightbox,
  collapsible filter panels (default OPEN — Playwright asserts form
  inputs visible), `@view-transition` cross-document nav.
  `hnvr-static` + module preStart now also ship `app.js`.
  New Playwright `ui-v2.spec.ts` (6 specs). Full suite: 29 passed +
  1 conditional skip.
  **Tombstone (verified) recording deletion (Aug 15 2026, late —
  v0.3.0.0)**: `segments.pending_delete_at` (migration 0006, wired
  into SchemaMigration — 0005 was NEVER wired, stays manual).
  PurgeRecordingAction stamps rows synchronously (all read paths
  filter `pending_delete_at IS NULL` → recording vanishes on
  redirect), forks `Hnvr.Web.PendingPurge.forkCameraPurge`: S3
  delete (row keys + day-prefix orphans minus a live-row protect
  set) → RE-LIST window → hard DELETE rows only when verified
  empty. 60 s sweeper (90 s grace) resumes batches whose worker
  died — the crash path that orphaned 98.6k objects. Verified both
  paths live on :18002 (21-row click purge; 141-row stale-batch
  resume). RetentionSweeper skips tombstoned rows. IHP schema
  parser rejects `--` comments INSIDE CREATE TABLE column lists —
  keep them outside. `S3.ConnectInfo` is NOT exported by
  Hnvr.Storage.S3 — pass S3Config and call connectInfo inside.
  Related same-day fixes: Layout now renders `renderFlashMessages`
  (was never rendered anywhere — `setSuccessMessage` was invisible;
  `.alert-success/.alert-danger` styles in src.css); dev MinIO hit
  `XMinioStorageFull` (drive 100%) leaving 98.6k orphan objects /
  41 GiB — cleaned via
  `mc rm --recursive --force local/hnvr-recordings/<slug>/2026-08-14/`
   (event thumbnails + init.mp4s kept; spool left for SpoolDrainer).
   Current version: **0.5.0.0** (ONVIF config sync — see top block).
  **App versioning (Aug 15 2026)**: single source of truth is
  `hnvr-web/hnvr-web.cabal` `version:` — bump on every feature/patch
  (feature → 2nd component, fix → 3rd+). `Hnvr.Web.version` re-exports
  it via `Paths_hnvr_web` (MUST be listed in the library's
  `autogen-modules` + `other-modules` or the link fails with an
  undefined closure). Surfaces: startup log line in LeaderMain/
  NodeMain (`starting hnvr-leader, hnvr v0.2.0.0`), unauthenticated
  `GET /status` JSON (`app/host/startedAt/uptimeSeconds/version`,
  middleware in `Hnvr.Web.Config` composed into the single
  CustomMiddleware option per pitfall #60), and a `v…` tag in the
    sidebar footer. Current version: **0.5.0.0** (ONVIF config sync;
   0.4.0.1 was the snapshot-claim guard
   vs duplicate capture on the leader host + minio-hs delete status
   check; 0.4.0.0 was event video clips; 0.3.0.0 was tombstone verified
   recording deletion; 0.2.0.0 was UI v2 + versioning).
  Phase 2 audit-and-fix pass landed Aug 10 2026 (see
  `.opencode/PHASE_AUDIT_REPORT.md` for the audit + ✅ badges on items
  that have been resolved; `.opencode/PHASE_AUDIT_REPORT_2.md` for the
  round-2 re-audit at `57aac3b`). Phase 1 slice 8 (Cameras admin gate)
  landed Aug 10 2026. Archive browser audit-fix landed Aug 12 2026
  (`8bd8d1f`: pageSize=10, filter-preserving delete, async S3 purge,
  LimitNOFILE bump). Phase 2 commit history:
  - `e08a1f7` docs: add initial HNVR design documentation
  - `ef3c743` scaffold: cabal multi-package project + flake.nix
  - `ece9519` phase 0: bootstrap IHP web + NATS bus + NixOS VMs
  - `3c45c46` phase 0 follow-ups: NATS wiring, cabal patches, worker VM broker
  - `a7a4885` … `41cd4b1` phase 1 (recording MVP, slices 1–7b)
  - `59f383b` phase 2: live view + multi-host (slices 1–6)
  - `57aac3b` phase 2 audit-fix: close 8 spec/CI/tooling gaps
  - phase 1 slice 8 (Cameras admin gate — IHP AuthSupport, users table,
    SessionsController, ensureIsUser beforeAction) — Aug 10 2026
  - `8bd8d1f` archive audit-fix: pageSize=10 + filter-preserving delete +
    async S3 purge + LimitNOFILE + 4 new pitfalls (#85–#88) — Aug 12 2026

## What this is

NVR for 6–20 RTSP cameras. Records 24/7 to SeaweedFS (S3 SaaS), runs YOLOv8n
detection via ONNX Runtime on the sub-stream, fires line-crossing/zone-intrusion
events, exposes an IHP web UI for live view (MediaMTX WebRTC), archive playback
(fMP4 HLS), events, and config. Two Nvidia hosts: hnvr-1 (GTX 1070, worker),
hnvr-2 (RTX 4090, leader). NATS JetStream as IPC spine. Manual ONVIF PTZ in v1;
auto-track via PID closed loop in v1.1.

**Full design**: `design_docs/00-overview.md` through `08-roadmap.md`. Read
`00-overview.md` for the locked decisions table and `08-roadmap.md` for the
phased plan. This file is the cheat-sheet; the design docs are authoritative.

## Locked tech stack

| | |
|---|---|
| Language | Haskell, **GHC 9.12.3** (nixpkgs `haskell.packages.ghc912`, IHP overlay applied) |
| Web | **IHP v1.6.0** (pinned via flake input `github:digitallyinduced/ihp/v1.6.0`) |
| Build | cabal multi-package + Nix flake |
| IPC | **NATS + JetStream** via @nats-queue@ (2017-era lib, patched for `network` >= 3.x; JetStream **deferred**) |
| Capture | ffmpeg subprocess (record `-c:v copy` main; analysis decode sub) |
| CV | ONNX Runtime via **internal ~150 LOC FFI binding** (not hs-onnxruntime-capi) |
| Models | YOLOv8n-320 ONNX, optional YOLOv8s-640 on RTX 4090 |
| Tracker | SORT in pure Haskell (~250 LOC) |
| Storage | **SeaweedFS** (S3 SaaS) + **PostgreSQL 18** (SaaS) — OUT of project scope |
| Live view | **MediaMTX v1.20.0** sidecar (RTSP → WebRTC WHEP), leader host only |
| Secrets | sops-nix |
| Deploy | NixOS flake, 2 hosts (`hnvr-1-vm`, `hnvr-2-vm` wired) |

## Verified commands (Aug 10 2026 — devenv-integrated devShell)

```bash
# Build everything (IHP overlay applied; first build ~30 min, then cached)
nix build .#hnvr-web

# Enter dev shell — devenv-integrated (Postgres, MinIO, NATS, MediaMTX
# wired as services; all HNVR_* env vars pre-set). MUST pass --no-pure-eval
# (or use direnv — .envrc already passes it).
nix develop --no-pure-eval

# Start all four services in another terminal (process-compose TUI):
devenv up

# Run the leader / node against devenv-managed services (env vars already set):
./result/bin/hnvr-leader   # PORT=18001, NATS=4222, PG via $DATABASE_URL
./result/bin/hnvr-node

# Cabal-side build of our own packages (NOT hnvr-web — see pitfalls #14):
cabal build hnvr-core hnvr-nats hnvr-storage hnvr-capture hnvr-cv hnvr-ptz

# Phase 1 capture pipeline integration binary (ffmpeg → Fmp4 → disk)
cabal build hnvr-record-frames
BIN=$(find dist-newstyle -name 'hnvr-record-frames' -type f -executable | head -1)
# Cam 197 (TCP), 196 (UDP!), 198 (TCP, XM firmware):
$BIN cam-197 tcp 'rtsp://admin:123456@192.168.0.197:554/h264PreviewCh01' /tmp/hnvr-out
$BIN cam-196 udp 'rtsp://admin:123456@192.168.0.196:554/h264PreviewCh01' /tmp/hnvr-out
$BIN cam-198 tcp 'rtsp://admin:io27pJ3wui@192.168.0.198:554/stream=0' /tmp/hnvr-out
# Output: /tmp/hnvr-out/<slug>/init.mp4 + /tmp/hnvr-out/<slug>/<YYYY-MM-DD>/<HH-MM-SS.MMM>.mp4
# Verify: cat init.mp4 frag.mp4 | ffprobe -   (fMP4 fragments need init segment)

# Phase 1 S3 wrapper integration binary (file → MinIO/SeaweedFS)
cabal build hnvr-s3-upload
S3BIN=$(find dist-newstyle -name 'hnvr-s3-upload' -type f -executable | head -1)
# Start MinIO locally (see pitfall #30 for the insecure-package bypass):
#   nix build --impure --expr '(import <nixpkgs> { ... }).minio'
#   MINIO_ROOT_USER=minioadmin MINIO_ROOT_PASSWORD=minioadmin minio \
#     server /tmp/minio-data --address :9100 &
#   mc alias set local http://localhost:9100 minioadmin minioadmin
#   mc mb local/hnvr-recordings
$S3BIN http://localhost:9100 minioadmin minioadmin hnvr-recordings \
  /tmp/hnvr-out/cam-197/init.mp4 cam-197/init.mp4

# Phase 1 supervised capture worker (full vertical slice)
cabal build hnvr-capture-loop
LOOPBIN=$(find dist-newstyle -name 'hnvr-capture-loop' -type f -executable | head -1)
# Local MinIO + NATS needed (see above +:
#   printf 'port: 4222\nhttp_port: 8222\nauthorization {\n  user: n\n  password: n\n}\n' > /tmp/nats.conf
#   nats-server -c /tmp/nats.conf -m 8222 &)
$LOOPBIN floor_2_5 tcp 'rtsp://192.168.0.197:554/user=admin&password=123456&channel=0&stream=MainStream' \
  --nats 'nats://n:n@localhost:4222' \
  --s3 http://localhost:9100 minioadmin minioadmin hnvr-recordings \
  --spool-dir /tmp/hnvr-spool \
  --host hnvr-2
# Verify: mc ls --recursive local/hnvr-recordings/floor_2_5/
#         curl -s http://localhost:8222/varz | grep in_msgs (should increment ~1/s/cam)
# Test backoff: pass a broken rtsp_url; watch the [cam INFO] log show
#                "ffmpeg exit → Backoff #N for Xs" with X = 2,4,8,16,30,...

# Run the binaries
HNVR_NATS_URI="nats://nats:nats@localhost:4222" PORT=18001 \
  ./result/bin/hnvr-leader  # IHP app + NATS connect; /healthz on PORT
# WARNING: do NOT run hnvr-node on the leader host — the leader binary
# already embeds the node role (pitfall #117; the snapshot-claim guard
# now refuses to start workers in that case). hnvr-node is for WORKER
# hosts only:
HNVR_NATS_URI="nats://nats:nats@<leader>:4222" HNVR_HOST=hnvr-1 \
  ./result/bin/hnvr-node    # worker host: HealthReporter + ConfigWatcher
# Prometheus metrics (both binaries; own warp, not IHP):
#   HNVR_METRICS_PORT=9102 curl localhost:9102/metrics   # devenv: MinIO owns :9100

# Build & boot a NixOS VM (leader). QEMU hostfwd uses COMMA separator
# for multiple ports — space-separated is silently dropped.
# Phase 2 needs to forward WebRTC (8889), API (9997), mediamtx debug.
nix build .#nixosConfigurations.hnvr-2-vm.config.system.build.vm
NIX_DISK_IMAGE=/tmp/leader.qcow2 \
  QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:18000-:8000,hostfwd=tcp:127.0.0.1:18222-:8222,hostfwd=tcp:127.0.0.1:18889-:8889,hostfwd=tcp:127.0.0.1:19997-:9997" \
  ./result/bin/run-nixos-vm
curl http://localhost:18000/healthz        # → 200 OK (WAI CustomMiddleware; works again post-Aug-10-2026 fix)
curl http://localhost:18000/               # → Dashboard (via startPage DashboardAction)
curl http://localhost:18000/Hosts          # → per-host panel (capital H — IHP-canonical URL)
curl http://localhost:18000/Dashboard      # → same as /
curl http://localhost:19997/v3/config/paths/list # → mediamtx v1.20+ live config (v2 removed)

# Worker VM (now also runs NATS broker so node has a local peer)
nix build .#nixosConfigurations.hnvr-1-vm.config.system.build.vm

# Formatter
nix fmt            # nixpkgs-fmt on .nix files

# Pre-commit checks (ormolu, hlint, nixpkgs-fmt)
nix build .#checks.x86_64-linux.pre-commit

# ---- Test suite (Aug 11 2026) -----------------------------------------
# All Haskell unit + property tests (fast lane; no services required)
cabal test hnvr-core hnvr-nats hnvr-storage hnvr-capture

# Same + integration tests against devenv MinIO/NATS (must `devenv up` first)
HNVR_TEST_INTEGRATION=1 cabal test hnvr-nats hnvr-storage

# NixOS leader smoke test (boots VM, curls /healthz + /NewSession; ~10 s)
nix build .#checks.x86_64-linux.hnvr-leader-smoke

# Playwright UI tests — chromium launches cleanly inside nix develop
# (chromiumRuntimeDeps in flake.nix wires NIX_LD_LIBRARY_PATH).
# Requires devenv services up + a leader on :18001.
cd tests/e2e && npm install && npx playwright install chromium   # one-time
nix develop --command bash -c 'cd tests/e2e && npm test'           # ~6 s
```

## Repo layout

```
hnvr/
├── design_docs/         11 files (00–08 original + 09-testing.md +
│                        10-test-plan.md added Aug 11 2026)
├── tests/
│   └── e2e/             Playwright TypeScript suite (S4/S5 Aug 11 2026
│                        + archive-browser slice Aug 12 2026)
│                        — login.spec, cameras-crud.spec, archive-playback.spec,
│                          live-view.spec, archive-browser.spec (14 specs),
│                          lib/auth.ts (loggedInPage fixture)
├── .github/workflows/   ci.yml (nix flake check + nix build .#hnvr-web/.#hnvr-nats
│                        + cabal-non-web + cabal-test-non-web + nightly playwright-e2e)
├── cabal.project        packages + allow-newer + vendored/nats-queue
├── flake.nix            ihp overlay + hnvrHaskellOverlay + nixosConfigurations
│                        + chromiumRuntimeDeps (S5 nix-ld wiring) +
│                        checks.hnvr-leader-smoke (S5 NixOS VM test)
├── flake.lock           pinned nixpkgs + flake-utils + pre-commit-hooks + ihp + devenv
├── nix/                (see "Repo layout — expanded nix/" block below)
├── vendored/
│   └── nats-queue/      2017 lib + sClose → close patch baked in
├── hnvr-core/           REAL types + S3-extracted pure logic
│   ├── src/Hnvr/Core/   Id, Geometry, Logging, Metrics, Prelude, Time,
│   │                    Segment, Crypto, Whep (extracted from hnvr-web S3),
│   │                    Assignment (extracted from hnvr-web S3),
│   │                    ArchiveBrowser (extracted from Web.Controller.Archive S3)
│   ├── test/            S1+S3 spec suite + ArchiveBrowserSpec (97 tests total)
│   └── app/CryptoTest.hs
├── hnvr-nats/           REAL Bus (nats-queue wrapper) + Subjects
│   └── test/            S2 spec suite (16 tests; env-gated integration)
├── hnvr-storage/        REAL S3 wrapper (minio-hs, NOT amazonka — see pitfall #28)
│   ├── src/Hnvr/Storage/S3.hs
│   ├── test/            S2 spec suite (5 tests; env-gated against MinIO)
│   └── app/S3Upload.hs  hnvr-s3-upload integration binary
├── hnvr-capture/        Fmp4 (REAL), Ffmpeg (REAL), Worker (REAL state machine);
│   ├── test/            S1+S2 spec suite (8 + 17 tests; Fmp4 chunk-boundary
│   │                    property is the anchor test)
│   └── app/             exes: hnvr-record-frames, hnvr-s3-upload, hnvr-capture-loop
├── hnvr-cv/             OnnxRuntime (REAL FFI binding + Internal vtable
│   │                    loader, smoke-tested vs libonnxruntime 1.24.4),
│   │                    Preprocess, Decode, Rules, AutoTrack,
│   │                    Tracker/Sort (stubs — land with Phase 3 slices)
│   ├── app/LeakProbe.hs hnvr-leak-probe: per-stage heap-leak bisect
│   │                    tool (pitfall #105); Soak.hs hnvr-cv-soak:
│   │                    live-stream bake runner (pitfall #106 RSS
│   │                    watch, per-EP inference stats); CompareModels.hs
│   │                    hnvr-cv-compare: yolov8n-320 vs yolov8s-640
│   │                    A/B accuracy tool (Phase 3 close-out)
│   └── test/            S6 started: OnnxRuntimeSpec (2 smoke tests,
│                        env-gated on HNVR_ONNXRUNTIME_LIB, pitfall #91)
├── hnvr-ptz/            Driver (REAL typeclass), Onvif (stub), Controller (stub)
├── hnvr-web/            Library + 2 executables (LeaderMain, NodeMain)
│                        ├── Application/Schema.sql   IHP schema source of truth
│                        ├── regen.sh                 regen+patch IHP codegen (see pitfall #32)
│                        ├── gen/Generated/...        IHP-generated types (committed)
│                        ├── src/Hnvr/Web.hs                 version stub
│                        ├── src/Hnvr/Web/Config.hs          IHP config + healthz + NATS init
│                        │                                  + EventWriter + HealthCache
│                        │                                  + AssignmentCoordinator (imports
│                        │                                    Hnvr.Core.Assignment — S3 extraction)
│                        │                                  + MediaMTXConfigSyncer
│                        ├── src/Hnvr/Web/FrontController.hs RootApplication + parseRoute
│                        ├── src/Web/Controller/Cameras.hs      CRUD + Probe + Assign
│                        ├── src/Web/Controller/Cameras/Probe.hs ffprobe JSON parser
│                        ├── src/Web/Controller/Support/Crypto.hs encryptPassword / decryptPassword / requireKey
│                        ├── src/Web/Controller/{Archive,Live,Dashboard,Hosts,Sessions}.hs
│                        ├── src/Hnvr/Web/{EventWriter,HealthCache,AssignmentCoordinator,
│                        │                  ConfigBroadcaster,MediaMTXConfigSyncer,WhepProxy,
│                        │                  Metrics}.hs
│                        │   (WhepProxy imports Hnvr.Core.Whep — S3 extraction)
│                        ├── src/Hnvr/Node/{HealthReporter,ConfigWatcher}.hs
│                        ├── src/Hnvr/Web/View/{Layout,Cameras/*,Archive/Player,Live/Show,
│                        │                  Dashboard/Index,Hosts/Index,Sessions/New}.hs
│                        └── app/{LeaderMain,NodeMain}.hs
├── nix/
│   ├── module.nix       NixOS module: hnvr-leader service (HNVR_HOST env wired)
│   ├── nats-server.nix  NixOS module: NATS + JetStream
│   ├── mediamtx.nix     NixOS module: MediaMTX sidecar (leader only)
│   └── secrets-template.yaml  sops-nix template (HNVR_DATA_KEY + S3 + DB)
```

## External services (SaaS — Sergey operates, not us)

| Service | Purpose | Where creds live |
|---------|---------|------------------|
| SeaweedFS | S3 API for fMP4 segments + thumbnails + exports | env `HNVR_S3_*` (sops-nix) |
| PostgreSQL 18 | Config, events, segments index, audit | env `HNVR_DB_URL` (sops-nix) |

We own: schema migrations (`hnvr-web/Application/Schema.sql` — TBD), backups
coordination. We do NOT own: PG ops, SeaweedFS ops, replication, vacuum.

## Test infrastructure (Aug 12 2026 — S1–S5 complete + archive-browser slice)

Test pyramid + framework rationale: `design_docs/09-testing.md`.
Per-package inventory + sprint schedule: `design_docs/10-test-plan.md`.
Both committed Aug 11 2026 (commit `fdf16e3`); S1–S5 delivered in 7 commits.
Archive-browser slice added Aug 12 2026 (commit `8bd8d1f`).

**143 Haskell tests + 20 Playwright specs + 1 NixOS VM smoke test.**

> Aug 13 2026: now **217 Haskell tests** (103 core + 35 capture +
> 58 cv + 16 nats + 5 storage) after the Phase 3 EKG slice.
> Aug 14 2026: now **272 Haskell tests** (119 core + 45 capture +
> 85 cv + 16 nats + 7 storage) after the Phase 3 close-out coverage
> pass (CameraSnapshot/Event/Frame, SpoolDrainer, Worker.transition,
> gated AnalyzerRunner loop, storage pure lane).

| Layer | Where | Status |
|-------|-------|--------|
| Unit + property (tasty + QuickCheck) | `hnvr-{core,nats,storage,capture}/test/` | 143 tests (97 core + 16 nats + 5 storage + 25 capture), all green via `cabal test` |
| Integration (NATS, S3 MinIO) | `hnvr-nats/test/Hnvr/Nats/BusSpec.hs`, `hnvr-storage/test/Hnvr/Storage/S3Spec.hs` | env-gated on `HNVR_TEST_INTEGRATION=1`; verified green against devenv services |
| Web UI (Playwright + chromium) | `tests/e2e/` | 20 specs (14 archive-browser + 1 archive-playback + 1 cameras-crud + 1 live-view + 3 login), all green; chromium launches cleanly inside `nix develop` via `chromiumRuntimeDeps` in flake.nix |
| NixOS VM smoke | `flake.nix` `#checks.x86_64-linux.hnvr-leader-smoke` | boots leader VM, asserts `/healthz` + `/NewSession`; runs in ~10 s; verified PASS |

**Verified commands** (Aug 11 2026):

```bash
# All Haskell unit + property tests (fast; no services required)
cabal test hnvr-core hnvr-nats hnvr-storage hnvr-capture

# Same + integration tests against devenv MinIO/NATS
HNVR_TEST_INTEGRATION=1 cabal test hnvr-nats hnvr-storage

# Pre-commit hooks (ormolu, cabal-fmt, nixpkgs-fmt, hlint)
nix build .#checks.x86_64-linux.pre-commit

# NixOS leader smoke test (boots VM, curls /healthz)
nix build .#checks.x86_64-linux.hnvr-leader-smoke

# Playwright UI tests (start devenv up + ./result/bin/hnvr-leader first)
cd tests/e2e && npm install && npx playwright install chromium
nix develop --command bash -c 'cd tests/e2e && npm test'

# ---- Phase 3 bake + accuracy tooling (Aug 14 2026) ------------------
# Both need the devenv env (HNVR_ONNXRUNTIME_LIB etc.) — run inside
# nix develop. Pull from the mediamtx relay (rtsp://localhost:8554/<slug>)
# rather than the camera directly when the production node is running
# (session caps, pitfall #11).
cabal build hnvr-cv:exe:hnvr-cv-soak hnvr-cv:exe:hnvr-cv-compare
SOAK=$(find dist-newstyle -name 'hnvr-cv-soak' -type f -executable | head -1)
CMP=$(find dist-newstyle -name 'hnvr-cv-compare' -type f -executable | head -1)
# Bake: production frameSourceLoop+runAnalyzer path; 60s tick reports
# decoded/dropped/analyzed, per-EP avg inference ms, VmRSS. --minutes
# bounds the run; without it, runs until Ctrl-C (final summary either way).
$SOAK 'rtsp://localhost:8554/floor_2_5' tcp 640x360 5 \
  ~/.local/share/hnvr/model_cache/yolov8/yolov8n-320.onnx \
  --scale 640x360 --minutes 360
# A/B accuracy: N frames through both models; per-frame detections at
# --conf (default 0.10), by-class summary, person-verdict disagreements,
# annotated PNGs with --png-dir. --scale = relay fallback shape.
$CMP 'rtsp://localhost:8554/backyard' tcp 1280x720 5 \
  ~/.local/share/hnvr/model_cache/yolov8/yolov8n-320.onnx \
  ~/.local/share/hnvr/model_cache/yolov8/yolov8s-640.onnx \
  --frames 30 --scale 1280x720 --png-dir /tmp/hnvr-compare
```

**CI matrix** (`.github/workflows/ci.yml`):
- `nix-flake-check` — `nix flake check` + `nix build .#hnvr-web` + `.#hnvr-nats`
- `cabal-non-web` — `cabal build` of the 6 non-IHP packages
- `cabal-test-non-web` — `cabal test hnvr-core hnvr-nats hnvr-storage hnvr-capture`
- `playwright-e2e` — nightly + on master; boots devenv + leader, runs npm test

**Env-gating pattern for integration tests**: tests look up
`HNVR_TEST_INTEGRATION` and silently skip with `pure ()` unless it's
`"1"`. Sergey's devenv-always-up workflow means integration tests are
run with `HNVR_TEST_INTEGRATION=1 cabal test`; CI runs only the pure
layer. See `Hnvr.Nats.BusSpec.integrationTest` for the canonical
helper.

**Pure-helper extraction pattern** (S3, when hnvr-web modules can't be
cabal-tested per pitfall #14): extract the pure decision logic into a
new `Hnvr.Core.<Name>` module, hnvr-web imports it and projects the
IHP record into the pure-shape type at the call site. Established
Aug 11 2026 with `Hnvr.Core.Whep` (from `WhepProxy`) and
`Hnvr.Core.Assignment` (from `AssignmentCoordinator`). Extended
Aug 12 2026 with `Hnvr.Core.ArchiveBrowser` (from
`Web.Controller.Archive` — pagination math, window resolution,
filter query-string round-trip, datetime-local parsing). Pattern is
generalisable to future leader-side testable extractions.

## Sergey's cameras (test fixtures — probed Aug 9 2026)

**Use Sergey's canonical URL form** (`user=admin&password=...&channel=0&stream=...`) —
it gives the true configured fps for every camera AND works over TCP for all
three (the alternative `h264PreviewCh01` URL on 196 is UDP-only and gives a
non-standard 25fps profile; the alternative `stream=0` on 198 gives 12fps
instead of 15 — both are probe artifacts of the wrong URL form).

| Slug | IP | User | Password | Main URL | Main codec/res/fps | Sub URL | Sub codec/res/fps |
|------|----|------|----------|----------|--------------------|---------|-------------------|
| low_ent | 192.168.0.198 | admin | `io27pJ3wui` | `rtsp://192.168.0.198:554/user=admin&password=io27pJ3wui&channel=0&stream=0` | HEVC 3072×2048 @15 | `...&stream=1` | HEVC 704×576 @5 (low for CV) |
| backyard | 192.168.0.196 | admin | `123456` | `rtsp://192.168.0.196:554/user=admin&password=123456&channel=0&stream=MainStream` | HEVC 4000×3000 @15 | `...&stream=SubStream` | HEVC 704×576 @5 |
| floor_2_5 | 192.168.0.197 | admin | `123456` | `rtsp://192.168.0.197:554/user=admin&password=123456&channel=0&stream=MainStream` | H.264 3840×2160 @15 | `...&stream=SubStream` | H.264 720×480 @15 |

All three work over `-rtsp_transport tcp`. Audio present on all three
(196: pcm_mulaw; 197: pcm_mulaw; 198: pcm_alaw). Phase 1 ignores audio.

**Vendor notes for later phases**:
- All three expose the H264DVR-style URL form above (`/user=&password=&channel=&stream=`),
  common to XM / icamra / generic Chinese OEM firmware.
- 196 + 197 also respond to ONVIF at `http://192.168.0.196/onvif/device_service`
  (gSOAP/2.8 server, Hikvision OEM namespaces) with WS-Security auth — useful
  for Phase 5 PTZ probe.
- 198 (low_ent) DOES have ONVIF (Aug 15 2026 correction) — XM firmware ships
  it DISABLED: no listener, `/onvif/*` 404s, and the `NetWork.ONVIF`
  DVRIP section reads null. Enabled live via python-dvr (OpenIPC) over
  NetSDK :34567: `set_info("NetWork.ONVIF", {"Enable": True, "Port": 8899})`
  (Ret 100; section then persists in the NetWork dump and :8899 opens).
  Media XAddr: `http://192.168.0.198:8899/onvif/media_service`; admin login
  works with the RTSP creds. WS-Discovery (UDP 3702 multicast) gets NO
  answers from any of the three cams on this LAN — don't use it to
  conclude ONVIF is absent. Cameras row updated: onvif_port=8899.
- 198 also exposes XMeye NetSDK on port 34567 — python-dvr
  (github.com/OpenIPC/python-dvr) speaks it: `DVRIPCam(ip, user, password)`,
  `.login()`, `.get_info("NetWork")` dumps the whole network config tree
  (individual `get_info("NetWork.X")` returns Ret 607 for sections that
  are null in the full dump — read the full tree instead).
- Encoder fps is only configurable via each camera's web admin UI.

**Sub-stream fps is low on 196 + 198 (5fps)** — borderline for CV. The
design's fallback path (`use_substream_for_analysis=false` →
main-stream-with-scale, design_docs/03 §2b) covers this. Decide per-camera
at Phase 3 kickoff.

ffprobe notes:
- ffmpeg 7.x renamed `-stimeout` → `-timeout` (use `-timeout 5000000` for RTSP).
- The H264DVR URL form uses `&` separators inside the path; quote the whole
  URL when passing to shell or ffmpeg.

## Sergey's hardware

| Host | GPU | Role |
|------|-----|-----|
| hnvr-1 | GTX 1070 (Pascal sm_61) | Worker — CUDA EP only, no TensorRT |
| hnvr-2 (this dev box) | RTX 4090 (Ada sm_89) | Leader — TensorRT EP + IHP + MediaMTX + NATS |

## Known pitfalls (do NOT re-discover these)

1. **GHC 9.12 jailbreaks** — instead of maintaining our own jailbreak list,
   we apply IHP's overlay (`ihp.overlays.default`) which already pins
   hasql to 1.10.3.7, jailbreaks hasql-interpolate, disables flaky tests
   (say, text-icu, cryptonite). Our packages layer on top of
   `pkgs.ghc912` exposed by that overlay.

2. **nats-queue is from 2017** — uses `Network.Socket.sClose` which was
   renamed to `close` in `network >= 3.x`. Patched in TWO places:
   `flake.nix` (overrideAttrs + substituteInPlace, for `nix build`)
   and `vendored/nats-queue/Network/Nats.hs` (for `cabal build`).
   Its test suite pulls in `cabal-test-quickcheck` (broken + base <4.14),
   so jailbreak + skip tests on the chain. No TLS, no JetStream.

3. **DerivingStrategies required** — any file using `deriving stock` /
   `deriving newtype` syntax needs `{-# LANGUAGE DerivingStrategies #-}`.

4. **`show Text` produces `"foo"` with quotes** — use `T.unpack` then `putStrLn`.

5. **ByteString JSON instances have constraint issues via newtype deriving** —
   for `Sha256` we dropped ToJSON/FromJSON for now. Re-add via hex encoding when
   the segment publisher is wired in Phase 1.

6. **IHP needs a Postgres at boot** — `withModelContext` is called by
   `IHP.Server.run` before serving HTTP. For the leader VM we run a local
   postgresql service. The SaaS Postgres plugs in via `DATABASE_URL`.
   /healthz works even when the DB is unreachable (our `CustomMiddleware`
   in `Hnvr.Web.Config` short-circuits before IHP's request flow).

7. **IHP disables library profiling** — `disableLibraryProfiling` is
   applied to all our packages in `flake.nix`'s `hnvrHaskellOverlay`.
   Without it, building our packages with profiling fails because IHP
   doesn't ship profiling libs (matches IHP's own `fastBuild`).

8. **Explicit class imports need `(..)`** — `import M (ClassName)` brings
   only the name; methods require `import M (ClassName (..))`.

9. **`OverloadedStrings` + `length` ambiguity** — don't write
   `length "nats://"`; the literal is `IsString a => a` and `length`
   can't pick a type. Use an explicit `String` binding or hardcode the
   numeric length.

10. **flakes require git-tracked files** — must `git add` new files
    before `nix build` will see them. "Git tree is dirty" warning is
    normal.

11. **Two RTSP sessions per camera** (record + analyze). Watch per-camera
    concurrent session cap (~4 on consumer IPCs) during host failover.

12. **`IHP.Prelude` is ClassyPrelude-like** — modules using it should
    `{-# LANGUAGE NoImplicitPrelude #-}` to avoid double-import warnings.

13. **Port 8000 may be occupied on Sergey's dev box** — Taiga runs there.
    Use `PORT=8002` or similar when running hnvr-leader outside a VM.

14. **`cabal build` of hnvr-web is unsupported** — IHP's transitive deps
    (mime-mail-ses → memory/crypton) need version pins that IHP's nix
    overlay applies but cabal doesn't see. **Confirmed Aug 11 2026: even
    with `pkgs.icu` + `pkgs.icu.dev` wired into devenv `packages` and
    `PKG_CONFIG_PATH=${pkgs.icu.dev}/lib/pkgconfig` set, `cabal build
    hnvr-web` still fails — `text-icu-0.7.1.0` itself has a GHC 9.12
    source-level incompatibility (`Word8` vs `Word16` in
    `Data.Text.ICU.Internal.hsc:58`); IHP's nix overlay patches
    text-icu but cabal can't see the patch.** The 6 non-IHP packages
    (core, nats, storage, capture, cv, ptz) are cabal-buildable; hnvr-web
    is `nix build .#hnvr-web` only. **Workaround for testing**: extract
    pure logic from hnvr-web modules into `Hnvr.Core.*` (testable via
    cabal). Pattern established Aug 11 2026 with
    `Hnvr.Core.Whep` (extracted from `Hnvr.Web.WhepProxy`) and
    `Hnvr.Core.Assignment` (extracted from
    `Hnvr.Web.AssignmentCoordinator`); hnvr-web imports these and
    projects IHP records into the pure-shape types at the call site.

15. **Cabal 3.16 `source-repository-package --patch-dir` is unreliable** —
    silently skips patches. Vendor patched source in-tree instead
    (`vendored/nats-queue/`).

16. **Nix 2.34 + recent nixpkgs `postgresql` family** — uses `<|` pipe-operator
    syntax which needs `experimental-features = nix-command flakes pipe-operators`
    in `~/.config/nix/nix.conf`. Already set on Sergey's box.

17. **`pg_config` must be on PATH for `cabal build`** — postgresql-libpq-configure
    (transitive via IHP) calls it. We install it via
    `nix profile install nixpkgs#postgresql_18.pg_config` (user profile).

18. **`addInitializer` runs in a linked `async`** — exceptions propagate
    to the main thread. Wrap any fallible IO in `E.catch` or your leader
    dies on every initializer hiccup. See `Hnvr.Web.Config.connectNats`.

19. **Qualified-import syntax** — `import M qualified as X` needs
    `ImportQualifiedPost`. Use the prefix form `import qualified M as X`
    (portable, no extension).

20. **`?context :: T` implicit-param syntax** requires
    `{-# LANGUAGE ImplicitParams #-}` in the file.

21. **Type signatures in lambda patterns** (`\(e :: SomeException) -> ...`)
    require `{-# LANGUAGE ScopedTypeVariables #-}`.

22. **`catch` is ambiguous** — IHP.Prelude re-exports `catch` from
    safe-exceptions; Control.Exception also exports one. Use
    `import qualified Control.Exception as E` and `E.catch`.

23. **QEMU hostfwd multiple ports** — use COMMA separator, not space.
    `hostfwd=...,hostfwd=...` works; space-separated silently drops the
    second forward.

24. **IHP's `addInitializer` callback type** is
    `(?context :: FrameworkConfig, ?modelContext :: ModelContext) => IO ()`
    — `ModelContext` is a specific type, not polymorphic.

25. **HEVC cameras emit 2+ fMP4 fragments per wall-clock second** —
    ffmpeg's `-frag_duration 1000000` requests 1s but the
    `+frag_keyframe` flag splits at every keyframe, and HEVC cameras
    (cam-196 in particular) keyframe more often than once per second.
    Object keys MUST use millisecond precision
    (`formatSegmentObjectKeyMs`), otherwise later fragments in the same
    second overwrite earlier ones on disk and in S3.

26. **fMP4 fragments are NOT independently playable** — ffprobe on a
    single `moof+mdat` file errors with `trun track id unknown, no tfhd
    was found`. That's expected; the track config lives in the
    `ftyp+moov` init segment. Verify by concatenating `init.mp4` with
    one or more fragments before probing. The HLS player does this
    naturally.

27. **`Data.Fixed.Milli` is a TYPE alias, not a constructor** —
    `Milli = Fixed E3`. To pattern-match the underlying Integer, use
    `MkFixed` from `Data.Fixed`: `let ms = realToFrac dt; MkInteger n = ms`.

28. **`amazonka-s3 2.0` doesn't compile under GHC 9.12 via cabal** — its
    generated STS modules use `DuplicateRecordFields` patterns that fail
    without the extension enabled. IHP's nix overlay patches this for
    `nix build`, but cabal can't mirror it. **`Hnvr.Storage.S3` uses
    `minio-hs` instead** — purpose-built for S3-compatible storage with
    path-style by default. Same API surface (putObject/getObject/
    presignUrl/listObjects/removeObject), no AWS-SDK baggage. Design
    doc `02-tech-stack.md` still says amazonka; treat as superseded.

29. **socks-0.5.6 doesn't compile under GHC 9.12** (pre-MonadFail API).
    `cabal.project` has `constraints: socks >= 0.6.0` to force the
    fixed version. minio-hs's upper bound doesn't reflect this.

30. **MinIO is `marked insecure` in nixpkgs** — must build/bypass with
    `nix build --impure --expr '(import <nixpkgs> { config.permittedInsecurePackages = [ "minio-..." ]; }).minio'`.
    For local testing of the S3 wrapper. Production uses SeaweedFS SaaS.

31. **`Hnvr.Nats.Bus.hostFromUri` requires `user:pass@host:port`** — bare
    `nats://localhost:4222` produces an empty host and crashes the nats-queue
    connection with `Network.Socket.getAddrInfo ... does not exist`. Always
    include dummy creds in the URI when the server has no auth.

32. **IHP v1.6.0 codegen has a primary-key encoder bug** — Create*/Update*
    /Fetch* statements wrap PK in `Encoders.nullable Mapping.encoder`
    instead of `Encoders.nonNullable Mapping.encoder`. The build fails
    with `Couldn't match type Id' "<table>" with Maybe a0`. Workaround:
    run `hnvr-web/regen.sh` after every Schema.sql change — it patches
    the generated files. Upstream IHP PR TBD.

33. **IHP v1.6.0 generated types require many cabal default-extensions** —
    when wiring `gen/` into hs-source-dirs, the cabal library stanza
    needs `OverloadedStrings, OverloadedLabels, DuplicateRecordFields,
    DisambiguateRecordFields, OverloadedRecordDot, NoFieldSelectors,
    ImplicitParams` plus the IHP-standard set. See hnvr-web.cabal.

34. **`hasql-mapping` 0.1.0.2 needed for IHP v1.6.0 generated code** —
    nixpkgs pins 0.1.0.1 which lacks the `IsScalar.encoder` signature
    the codegen expects. The flake.nix `hnvrHaskellOverlay` overrides via
    `final.callHackageDirect` with the tarball hash. Bump hash if
    hasql-mapping re-releases.

35. **IHP HSX can't parse nested record patterns** — `pathTo FooAction { id = x }`
    inside an HSX expression hole fails with "parse error (possibly
    incorrect indentation or mismatched brackets)". Workaround: extract
    the path to a `let`/`where` binding and reference it as a single var.

36. **IHP `Html` type carries implicit-param constraint**
    `(?context :: RequestContext, ?request :: Request)` — so any function
    with `Html` in its signature needs the params in scope, which means
    either (a) no explicit signature (let GHC infer), or (b) RankNTypes.
    Easiest in views: omit signatures on local helpers.

37. **IHP controllers need `Data` + `AutoRoute` instances** —
    declaring `data CamerasController = IndexAction | ... ` is not enough;
    add `deriving stock (Eq, Show, Data)` (needs DeriveDataTypeable) plus
    `instance AutoRoute CamerasController` to get `parseRoute` dispatch.
    Route helpers like `redirectTo EditAction {..}` use the data
    constructor names directly (not `EditCameraAction`-style auto-aliases).

   38. **cabal `exposed-modules` MUST NOT have duplicate entries** — even
       comment lines between two listings of the same module produce a
       Cabal-5559 "duplicate-modules" error at configure time. Watch for
       stale list copies when refactoring.

   39. **IHP `Id' "table"` has no `ConvertibleStrings Text` instance** —
       `cs (h.id :: Id' "hosts") :: Text` fails with "Could not deduce
       ConvertibleStrings". Use `Data.Coerce.coerce h.id :: Text` (works
       because `Id'` is a `newtype` around `PrimaryKey table`). The
       pattern `case h.id of Id t -> t` also works but needs the
       constructor imported from `IHP.ModelSupport`.

   40. **IHP HSX can't parse lambda-piped `forEach`** — `forEach xs (\x ->
       [hsx|...|])` inside an HSX `[hsx|...|]` block triggers
       `parse error on input ')'`. Extract the inner HSX to a
       top-level helper (`renderLi x = [hsx|...|]`) and use
       `forEach xs renderLi`.

   41. **Hasql 1.9.x has no Notification module** — for LISTEN/NOTIFY,
       use `postgresql-simple` (already in IHP's transitive deps). Open
       a dedicated `PG.Connection` via `PG.connectPostgreSQL` outside
       IHP's Hasql pool (LISTEN must hold the connection idle to
       receive notifies). `PG.getNotification` blocks; wrap in
       `forever`.

    42. **IHP v1.6.0 `sqlExec`/`unsafeSqlExec` are broken for DDL** — emits
        `-Wdeprecations` warnings AND fails at runtime on DDL
        (`CREATE FUNCTION`, `CREATE TRIGGER`, `DROP TRIGGER IF EXISTS`)
        with `UnexpectedResultStatementError "Empty bytes"`: the IHP
        Statement is built with a row-expecting decoder regardless of
        the doc claim that `unsafeSqlExec` is the DDL escape hatch —
        they're true aliases. **Workaround: use `postgresql-simple`
        (already in IHP's transitive deps) for any DDL.** Open a
        one-shot `PG.connectPostgreSQL` connection, `PG.execute_` the
        statements, `PG.close`. `Hnvr.Web.MediaMTXConfigSyncer.ensureTrigger`
        is the canonical example. The recommended `[typedSql|...|]`
        + `sqlExecTyped` quasi-quoter doesn't cover `CREATE FUNCTION`
        either, so DDL stays on pg-simple indefinitely.

   43. **IHP HSX `<video playsinline>` is rejected** — parser allows
       only a fixed attribute whitelist. Drop `playsinline` (Chrome
       plays inline anyway when the element is `autoplay muted`).

   44. **mediamtx REST config API** — `PUT /v2/config/paths/<id>` is
       upsert, `DELETE /v2/config/paths/<id>` removes. `GET /v2/config/paths`
       returns `{pathName: {...}, ...}` — top-level keys are path IDs.
       We use per-path ops, not the global PUT (which version-semantics
       vary across mediamtx releases).

   45. **mediamtx config SIGHUP needs polkit/systemctl; REST is simpler** —
       the leader runs as `hnvr` user, so does mediamtx. Same-user
       `kill(2)` would work if we exposed the PID, but
       `systemctl kill -s HUP` needs polkit. We use the REST API for
       live reload and write `/run/hnvr/mediamtx.yml` as the source of
       truth at mediamtx boot.

   46. **NoFieldSelectors + record fields** — with `NoFieldSelectors`
        enabled, `recField rec` (function application style) doesn't
        compile. Use `rec.recField` (OverloadedRecordDot). The cabal
        default-extensions include both.

   47. **`nix build .#hnvr-web` requires new modules to be `git add`-ed
       BEFORE invoking nix** — `callCabal2nix` only sees files in the
       git tree (pitfall #10 generalised). Adding a new module to
       `exposed-modules` without `git add`-ing the .hs file fails with
       `can't find source for Hnvr/Web/<Mod>` at the cabal configure
       step. Pre-stage with `git add` before any `nix build` after a
       new-module commit.

   48. **cabal-fmt and ormolu are pre-commit hooks now** (Aug 10 2026
       audit-fix) — `.cabal` files use 2-space indent + leading-comma
       field lists; `.hs` files use ormolu's compact record/list style
       (e.g. `Record{ field = value }` not `Record { field = value }`).
       `cabal-fmt -i` and `ormolu -i` over the tree before commit if
       you've edited anything sizeable.

   49. **IHP v1.6.0 `AuthMiddleware` lives in `IHP.FrameworkConfig.Types`**
       (Aug 10 2026 slice 8) — NOT in `IHP.LoginSupport.Middleware`.
       The latter only exports the `authMiddleware`/`adminAuthMiddleware`
       functions. Import pattern:
       `import IHP.FrameworkConfig.Types (AuthMiddleware (..), FrameworkConfig)`
       + `import IHP.LoginSupport.Middleware (authMiddleware)`.

   50. **Type family instances must be explicitly imported** (Aug 10 2026
       slice 8) — `type instance CurrentUserRecord = User` declared in
       `Hnvr.Web.Auth` is invisible to GHC unless the consuming module
       imports that module (`import Hnvr.Web.Auth ()` is enough). Without
       the import, `authMiddleware @User` and `ensureIsUser` fail with
       "Couldn't match type CurrentUserRecord with User". Affects every
       module that touches `authMiddleware @User` / `ensureIsUser` /
       `currentUserOrNothing` — currently `Config.hs`,
       `Web/Controller/Cameras.hs` (renamed from `Hnvr.Web.Controller.*`
       in commit `ce739c1`, see pitfall #59), `View/Layout.hs`. Add the
       empty import wherever IHP auth is used.

   51. **`regen.sh` does NOT touch `hnvr-web.cabal`** (Aug 10 2026 slice 8) —
       when adding a new table to `Schema.sql`, after `./hnvr-web/regen.sh`
       you must hand-add the new `Generated.<Table>`,
       `Generated.<Table>Include`, `Generated.ActualTypes.<Table>`,
       `Generated.Statements.{Create,CreateMany,Fetch,Update,RowDecoder}<Table>`
       entries to `exposed-modules` in `hnvr-web.cabal`. Missing entries
       pass type-checking but fail at link with `undefined reference to
       Generatedzi<table>zi..._closure` errors.

   52. **IHP v1.6.0 auth — old `LoginSupport.User` class is GONE** (Aug 10
       2026 slice 8) — replaced by `class HasNewSessionUrl user` + open
       type family `CurrentUserRecord`, both in `IHP.LoginSupport.Types`.
       The whole user-side instance surface is:
       ```
       instance HasNewSessionUrl User where
         newSessionUrl _ = "/NewSession"
       type instance CurrentUserRecord = User
       ```
       No methods to implement beyond `newSessionUrl`. Sessions
       controller is `action NewSessionAction = Sessions.newSessionAction @User`
       + 2 more from `IHP.AuthSupport.Controller.Sessions`. `beforeAction`
       gate is `ensureIsUser` from `IHP.LoginSupport.Helper.Controller`.
       Routes are top-level: `/NewSession`, `/CreateSession`, `/DeleteSession`.

   53. **IHP v1.6.0 `ensureIsUser` is NOT in `IHP.ControllerPrelude`** (Aug 10
       2026 slice 8) — add explicit `import IHP.LoginSupport.Helper.Controller (ensureIsUser)`.
       `currentUserOrNothing` IS re-exported via `IHP.ViewPrelude` from
       `IHP.LoginSupport.Helper.View` — don't double-import in views.

   54. **`hashPassword`/`verifyPassword` come from `IHP.AuthSupport.Authentication`**
       (Aug 10 2026 slice 8) — uses `pwstore-fast` under the hood (sha256
       with 17 rounds, format `sha256|17|...`). Re-exported by
       `IHP.ControllerPrelude` for controller contexts but in
       initializers (`Config.hs`) you need the explicit import. Returns
       `IO Text`. No `bcrypt-hs` dependency needed; it's all transitive
       via `ihp`.

   55. **devenv flake integration** (Aug 10 2026) — `devShells.default`
       is now `devenv.lib.mkShell` (NOT `pkgs.mkShell`). Things to know:
       - **`nix develop` MUST pass `--no-pure-eval`** — devenv needs to
         resolve `PWD` to locate state dir (`.devenv/state/`). direnv
         already does this (`.envrc` has `use flake . --no-pure-eval`).
         Pure-eval `nix develop` falls back to `inputs.self.outPath`
         which is read-only and crashes on first write.
       - **Services live via `devenv up`** in a separate terminal —
         process-compose TUI shows Postgres (:15432), MinIO (:9100/:9101),
         NATS (:4222, monitor :8222), MediaMTX (:9997, WebRTC :8889).
         Ctrl-C or `q` stops everything. No `nixosModules` or systemd
         units needed for local dev.
       - **MinIO requires `permittedInsecurePackages`** — dev only;
         `devenvPkgs = import nixpkgs { config = ...; }` constructs a
         separate pkgs instance just for the devShell. Production uses
         the SeaweedFS SaaS.
       - **Port 15432, not 5432, for devenv PG** — Sergey's dev box
         runs a system postgres on :5432 (langfuse /
         `postgresql-with-zulip-dicts`). devenv PG binds :15432;
         `DATABASE_URL=postgresql:///hnvr?host=127.0.0.1&port=15432`.
         Symptom if forgotten: PG shows "not ready" in TUI → restart
         loop → "failed".
       - **Stale `.devenv/state/postgres/` after config changes** —
         devenv only writes `pg_hba.conf` + `postgresql.conf` during
         `initdb`; on subsequent starts the existing datadir is reused
         with OLD config. Fix: `~/bin/devenv-kill --reset-pg` then
         `devenv up` again.
       - **MediaMTX 1.20.0 (was 1.18.2, bumped Aug 10 2026)** — overlay
         in flake.nix overrides nixpkgs to v1.20.0 via buildGo126Module
         (vendorHash + hls.js v1.6.16 fetched separately). API stays
         `/v3/*` so the readiness probe is unchanged. **`Hnvr.Web.
         MediaMTXConfigSyncer` still calls `PUT /v2/config/paths/<slug>`
         which 404s — tracked in Taiga issue #467** (Priority High,
         Severity Important, blocks Phase 2 Slice 3 WHEP demo). Fix:
         migrate to `/v3/config/paths/{add,patch}/<slug>` per v1.20.0
         openapi.yaml. The bug is in our code (mediamtx migrated in
         v1.16), not a version issue — v1.20.0 bump did NOT auto-fix it.
       - **MediaMTX crashes if HLS port :8888 collides** — Sergey's box
         has another service on :8888. Bootstrap config
         (`mediamtxBootstrap` in flake.nix) sets `rtsp/rtmp/hls/srt/
         playback: no` since HNVR only uses API + WebRTC.
       - **Stopping a hung devenv** — `~/bin/devenv-kill` (committed
         locally to ~/bin, not the repo). Scoped to `/nix/store/...`
         paths so it never touches Sergey's system services.
        Env vars consumed by HNVR binaries (`HNVR_NATS_URI`, `HNVR_S3_*`,
        `DATABASE_URL`, `HNVR_MEDIAMTX_*`, `PORT=18001`, `HNVR_DATA_KEY`)
        are pre-wired —
       cabal-built binaries drop straight into the running services.
       `nix flake check --no-build --keep-going` passes for `devShells.*`,
       `packages.*`, `checks.*`, `formatter`, `nixosModules.*`; the
       pre-existing `nixosConfigurations.hnvr-{1,2}-vm` failure (missing
       `fileSystems` + `boot.loader.grub.devices` assertions) is unrelated
        and predates devenv.

   56. **Web UI build pipeline — Tailwind standalone CLI** (Aug 10 2026) —       CSS lives in `hnvr-web/static/src.css` (input) and compiles to
       `hnvr-web/static/app.css` via the **tailwind standalone CLI**
       (`nixpkgs#tailwindcss`, v3.4.17) — **no npm, no node, no postcss**.
       Component classes via `@apply` are defined in `src.css`; HSX views
       use semantic class names (`.btn`, `.card`, `.led`, `.badge`, etc.).
       Things to know:
       - **Production**: `flake.nix`'s `hnvr-static` derivation (exposed
         via `hnvrTopOverlay` so `pkgs.hnvr-static` resolves in NixOS)
         runs `tailwindcss --minify` to produce `$out/app.css`. The
         `services.hnvr.leader.staticAssets` option (nix/module.nix)
         defaults to this derivation; preStart copies it into
         `${dataDir}/static/app.css` (idempotent on every service start).
       - **Dev**: `devenv up` runs a tailwind watcher process
         (`processes.tailwind.exec`) that rebuilds
         `hnvr-web/static/app.css` on HSX/src.css changes. The dev
         leader binary serves it via `APP_STATIC=hnvr-web/static`
         (relative to CWD — Sergey runs from repo root).
       - **First-time dev setup**: if `hnvr-web/static/app.css` doesn't
         exist (e.g. fresh checkout, watcher not yet run), the leader
         serves a 404 for `/static/app.css` and pages render unstyled.
         Manual rebuild: `cd hnvr-web && tailwindcss --input static/src.css --output static/app.css --minify`.
       - **Tailwind pitfall: `@apply group` is rejected** — the `group`
         utility is a marker class, not a real CSS property. Put `group`
         directly in HSX alongside the component class
         (`<div class="cam-card group">`) instead of via `@apply`.
       - **Tailwind pitfall: `tailwind.config.js` `content` globs are
         resolved relative to the config file** — the `hnvr-static`
         derivation copies the whole `hnvr-web/` tree as `src` so
         tailwind can scan `src/Hnvr/Web/View/**/*.hs` for class names.
       - **IHP static serving**: IHP's static middleware reads
         `APP_STATIC` env (default `"static/"` relative to CWD). Module
         already wires `APP_STATIC = "${cfg.dataDir}/static"`. Files in
         that dir are served at `/static/<filename>` with proper cache
         headers (no cache in dev, `max-age=forever` in prod with
         asset-path hash busting via `IHP_ASSET_VERSION`).
        - **`Html`-typed local helpers** (pitfall #36 still applies) —
          keep view helpers in the `where` block of the `View` instance
          method so the implicit-param constraint flows from the
          enclosing scope; top-level helpers need either
          `(?context :: RequestContext, ?request :: Request) =>` or no
          signature.

    57. **`HNVR_DATA_KEY` must be set before any Cameras CRUD write** (Aug 10
       2026) — `Web.Controller.Support.Crypto.requireKey` throws
       `userError "HNVR_DATA_KEY not set; cannot encrypt/decrypt camera
       passwords"` at the action level if missing. Symptom: `/NewCamera`
       form POST → IHP exception page. Fix landed in devenv: a stable
       dev-only base64 32-byte key is baked into the `env` block in
       `flake.nix` (matches the `INITIAL_ADMIN_PASSWORD` dev-convenience
       pattern). Production sources via sops-nix (Phase 6).

    58. **hasql serialises `String` as a PG array, not TEXT** (Aug 10 2026) —
       `Env.lookupEnv` returns `IO (Maybe String)` and `String = [Char]`.
       Passing that `String` straight to `sqlExec`'s tuple makes hasql
       pick the `[Char]` `ToField` instance, which encodes a PG **array**
       of char — the value lands in the column as `{a,d,m,i,n,@,...}`
       instead of `admin@hnvr.local`. Symptom: IHP's
       `filterWhereCaseInsensitive (#email, ...)` in
       `createSessionAction` never matches, so login always 302s back
       to `/NewSession` with "Invalid Credentials". Fix: `cs` to `Text`
       before the SQL tuple: `let emailT = cs email :: Text in sqlExec
       ... (emailT, hash)`. Rule: never pass a `String` to hasql —
       always coerce to `Text` first.

       While here: `Hnvr.Web.Config.config` now `setEnv "APP_STATIC"
       "hnvr-web/static"` when the env var is unset, so the dev leader
       binary serves `/static/app.css` without needing
       `APP_STATIC=hnvr-web/static` on the command line. Production
       overrides via `nix/module.nix`'s `APP_STATIC = "${dataDir}/static"`.
       And devenv's env block now ships dev defaults
       (`admin@hnvr.local` / `hnvr-dev`) so `devenv up` + leader just
       works.

   59. **IHP `actionPrefixText` derives URL prefix from the controller
       module's FIRST dot-segment** (Aug 10 2026, commit `ce739c1`) —
       modules under `Hnvr.Web.Controller.*` got the URL prefix `/hnvr/`
       (not `/`), so every route 404'd with "Action not found". IHP's
       `IHP.RouterSupport` isPrefixOf check matches `"Web."` literally,
       so controllers MUST live under `Web.Controller.*` for the prefix
       to collapse to `/`. Symptom: `curl http://localhost:18000/` →
       404 "Action not found" while `curl http://localhost:18000/hnvr/`
       worked. Fix: `git mv hnvr-web/src/Hnvr/Web/Controller
       hnvr-web/src/Web/Controller` + update all imports. Views stay
       under `Hnvr.Web.View.*` (only the `isPrefixOf "Web."` check on
       controllers matters). **Always put IHP controllers under
       `Web.Controller.*`, never namespaced under the project name.**

       Companion gotcha: IHP AutoRoute generates URLs from constructor
       names, so `IndexAction` in every controller collides on `/Index`.
       Use IHP-canonical per-resource form: `CamerasAction`,
       `ShowCameraAction`, `EditCameraAction`, `CreateCameraAction`,
       `UpdateCameraAction`, `DeleteCameraAction`, `ProbeCameraAction`,
       `AssignCameraAction`, `HostsAction`, `DashboardAction`,
       `PlayerArchiveAction`, `PlaylistArchiveAction`, `ShowLiveAction`.
       Sessions is already canonical (`NewSessionAction` /
       `CreateSessionAction` / `DeleteSessionAction`) — left as-is.

       Companion: `startPage DashboardAction` in the `FrontController`
       instance maps `/` → the named action without consuming an
       AutoRoute slot. Use it for the root URL (don't try to make an
       `IndexAction` live at `/`).

       Open follow-up: `/healthz` 404s — `Config.hs`'s `CustomMiddleware`
       is not being applied by IHP v1.6.0's middleware chain. Tracked
       separately. **Closed Aug 10 2026**: see pitfall #60.

   60. **IHP `option` is FIRST-write-wins, not last-write-wins** (Aug 10
       2026) — `IHP.FrameworkConfig.option` is implemented as
       `State.modify (\map -> if TMap.member @option map then map else TMap.insert value map)`
       (i.e. insert-if-absent). And `buildFrameworkConfig` runs
       `appConfig >> ihpDefaultConfig` — user config FIRST, defaults
       SECOND. So calling `option $ CustomMiddleware X` followed by
       `option $ CustomMiddleware Y` silently DROPS Y. Symptom: Sergey
       had two `option $ CustomMiddleware` calls (whep + healthz); only
       whep was active, so `/healthz` 404'd for all of Phase 2. Fix:
       compose into one CustomMiddleware call:
       `option $ CustomMiddleware (whepMiddleware . healthzMiddleware)`.
       Same trap applies to any other option type — check the IHP
       source if a `option` call seems to have no effect. Affects:
       `CustomMiddleware`, `AuthMiddleware`, `SessionCookie`,
       `RLSAuthenticatedRole`, etc.

   61. **MediaMTX v1.16+ split the upsert PUT into add/patch/delete**
       (Aug 10 2026, Taiga #467 closed) — the old `PUT /v2/config/paths/<id>`
       is GONE in v1.20.0. v3 API surface (confirmed against
       `internal/api/api.go` of mediamtx v1.20.0):
         * `GET    /v3/config/paths/list`              → `{itemCount, pageCount, items:[...]}`
         * `GET    /v3/config/paths/get/<name>`        → single path object
         * `POST   /v3/config/paths/add/<name>`        → create, 400 if exists
         * `PATCH  /v3/config/paths/patch/<name>`      → patch, 404 if not exists
         * `POST   /v3/config/paths/replace/<name>`    → replace, 404 if not exists
         * `DELETE /v3/config/paths/delete/<name>`     → delete, 404 if not exists
       Methods MATTER: `add` is POST, `patch` is PATCH, `delete` is
       DELETE. `Hnvr.Web.MediaMTXConfigSyncer.pushPaths` does
       list → diff → for each desired: `add` if new, `patch` if exists;
       for orphans: `delete`. List response is `{items:[{name,...}]}`,
       NOT the old map form — decode with `Aeson.Types.parseMaybe` +
       `withObject "PathList" (.: "items")`. Read-only endpoints are
       auth-free in default config; mutating endpoints need either
       no auth configured or a credentials header (we run with
       `api: yes` and no auth in dev/leader).

   62. **WAI Middleware composition order** (Aug 10 2026) — when composing
       `Middleware`s with `.`, the LEFTMOST runs FIRST on incoming
       requests: `(f . g) app = f (g app)`. So
       `whepMiddleware . healthzMiddleware` means whep gets the request
       first (matches `/whep/*`), then healthz (`/healthz`), then IHP.
       Put the most-specific path-prefix middleware leftmost.

   63. **IHP HSX does NOT splice `{...}` inside `<script>` or `<style>`
       tags** (Aug 10 2026) — `ihp-hsx/IHP/HSX/Parser.hs:111-124` treats
       script/style bodies as pre-escaped raw text (so CSS like
       `h1 { color:red }` doesn't get re-parsed as a splice). Symptom:
       `[hsx|<script>{myJs}</script>|]` outputs the literal string
       `{myJs}` as JS → browser JS parse error
       (`Uncaught SyntaxError: missing ) after argument list` at
       column 1, since the literal text starts with `{`). Both
       `View/Live/Show.hs` and `View/Archive/Player.hs` had this bug
       for ~all of Phase 2 (live view JS never ran, archive player
       silently no-op'd). Fix: build the entire `<script>…</script>`
       element in Haskell and inject as a single body-level splice:
       ```haskell
       [hsx|
         ...
         <div>...</div>
         {scriptTag}
       |]
         where
           scriptTag = preEscapedTextValue ("<script>" <> js <> "</script>" :: Text)
       ```
       Verify via `curl -b cookie http://leader/ShowLive?... | grep script` —
       you should see actual JS, not `{preEscapedTextValue …}`.

    64. **nixpkgs `xorg.*` attribute naming is inconsistent** (Aug 11 2026
        S5 chromium runtime deps) — there is no rule, every attr has to be
        tested. The cases that bit me:
        - `xorg.libx11` ❌ → `xorg.libX11` ✓
        - `xorg.libXscrnsaver` ❌ → `xorg.libXScrnSaver` ✓
        - `xorg.libXshmfence` ❌ → `xorg.libxshmfence` ✓ (lowercase 's'!)
        - `xorg.libxcb` ✓ (correct as lowercase, NOT `libXcb`)
        Quick check before committing a list:
        `nix eval --impure --raw --expr 'let pkgs = import <nixpkgs> {}; in if pkgs.xorg ? ATTR then "yes" else "no"'`.

    65. **`libgbm` is a separate nixpkgs package, NOT in `pkgs.mesa`**
        (Aug 11 2026 S5) — `mesa` ships libGL but `libgbm.so.1` lives in
        `pkgs.mesa-libgbm`/`pkgs.libgbm`. Chromium and Playwright's
        chrome-headless-shell both need it. The full chromium runtime
        deps list (verified working Aug 11 2026) is the
        `chromiumRuntimeDeps` binding in flake.nix — copy from there
        rather than re-deriving.

    66. **`pkgs.nixosTest` was renamed to `pkgs.testers.nixosTest`**
        (renamed 2025-10-27, converted to throw) — using the old name
        produces `error: 'nixosTest' has been renamed to/replaced by
        'testers.nixosTest'`. Documented in `nixpkgs/pkgs/top-level/
        aliases.nix`. Always use `pkgs.testers.nixosTest` for VM tests
        now; same API.

    67. **IHP AutoRoute maps `DeleteCameraAction` to HTTP DELETE, not POST**
        (Aug 11 2026 S5) — verified via curl: POST returns 405, DELETE
        returns 302 (success). The Cameras controller comment line 16
        documents this (`@/DeleteCamera?cameraId=…@ (DELETE)`) — IHP's
        convention is to use the HTTP method matching the action verb
        prefix (Create→POST, Update→POST, Delete→DELETE). HTML forms
        can't do DELETE natively, so v1 has no UI for delete — the
        Playwright test calls it via `page.request.delete(...)` directly.

        Companion: **Playwright's `page.request.delete()` follows 302
        redirects with the SAME method (DELETE)**, which 405s on the
        redirect target (`/Cameras` doesn't accept DELETE). Use
        `{maxRedirects: 0}` + `expect(resp.status()).toBe(302)` to
        short-circuit.

    68. **Headless chromium reports `canPlayType('application/vnd.apple.
        mpegurl')` as `'maybe'`** (truthy) — even in `chrome-headless-shell`
        (no real Safari involved). This means the View/Archive/Player.hs
        "Native HLS (Safari)" branch fires under headless chromium, so
        the status pill text becomes `"Native HLS (Safari)"` rather
        than `"Loading player…"`. Playwright tests on this page must
        accept either branch; pinning to `"Loading player…"` is a
        timing-sensitive flake.

    69. **cabal test target syntax is `pkg:testsuite-name`, not
        `pkg:test:testsuite-name`** (Aug 11 2026 S1) — the latter gives
        "Unknown target". The full form: `cabal test hnvr-core:hnvr-core-test`
        where `hnvr-core-test` is the value of the `test-suite` stanza's
        `name` field. `cabal test hnvr-core` (no component) runs ALL
        test-suites in that package; the explicit form lets you scope
        to one when iterating.

    70. **The `cabal test` exit code propagates** (Aug 11 2026 S1) —
        `cabal test` returns non-zero on test failure AND on build
        failure. CI jobs that gate merges on cabal-test should use
        `cabal test` directly (not `cabal build && cabal test`) so a
        compile failure isn't double-counted.

    71. **`time-1.14` (GHC 9.12) hides the `UTCTime` constructor** (Aug
        11 2026 S1) — `import Data.Time.Clock (UTCTime)` brings only the
        TYPE; the constructor needs explicit `(..)`:
        `import Data.Time.Clock (UTCTime (..))`. Without it, GHC errors
        with `[GHC-01928] Illegal term-level use of the type constructor
        'UTCTime'`. No `mkUTCTime` shim exists in this version; the
        pattern `UTCTime day diffTime` still works once the constructor
        is in scope.

    72. **IHP `Id' "table"` constructor import** (Aug 11 2026 M1) — to
        extract the underlying `UUID` from a `Camera`'s `id` field for
        wire transmission, neither `Data.Coerce.coerce` nor the
        apparent `import IHP.ModelSupport (Id (..))` works. Coerce
        fails with `[GHC-18872] Couldn't match representation ... The
        data constructor 'IHP.ModelSupport.Types.Id' of newtype
        'IHP.ModelSupport.Types.Id'' is not in scope`. The `Id (..)`
        import only brings the TYPE alias into scope (no constructor).
        **Working pattern**:
        ```haskell
        import IHP.ModelSupport (Id' (Id))
        ...
        case cam |> get #id of Id uuid -> uuid
        ```
        `Id'` is the type constructor (with prime); `Id` (no prime) is
        the data constructor. `IHP.ModelSupport (Id' (Id))` exports
        both correctly. The generated code in `View/Hosts/Index.hs`
        uses `Data.Coerce (coerce)` to `Text` and works because
        `IHP.ViewPrelude` re-exports the constructor transitively.

    73. **`file-embed`'s `embedFile` vs `embedFileRelative` under nix
        sandbox** (Aug 11 2026 M2) — `embedFileRelative` claims to
        resolve relative to the source file but in nix sandbox it
        resolves relative to CWD (the package root). Result: the same
        splice works under cabal but errors out under nix build with
        `/build/hnvr-web/../../Application/Schema.sql: does not exist`.
        **Use `embedFile "Application/Schema.sql"`** (CWD-relative,
        works in both) for any file outside the cabal `hs-source-dirs`
        listing. CWD is reliably set to the package root by both
        cabal-install and nix's `callCabal2nix`.

    74. **`postgresql-simple-migration` 0.1.15.0 API** (Aug 11 2026 M2):
        - `MigrationResult` is **kind `* -> *`**, parameterized by the
          error payload type. `MigrationInitialization` produces
          `MigrationResult String`, `MigrationScript` produces
          `MigrationResult ByteString`. Write handlers as
          `Show a => ... -> MigrationResult a -> ...` or split into
          two specialized handlers.
        - Constructors: `MigrationSuccess` (no payload) and
          `MigrationError a` (payload of type `a`).
        - `runMigration` requires the caller to wrap in
          `withTransaction` — the library does NOT auto-commit.
        - Hackage 0.1.15.0 cabal revision 1 + nixpkgs both ship the
          `* -> *` version. The plain `data MigrationResult` shape
          shown in old blog posts is from a pre-0.1.x release.
        - The library's `bytestring <0.11`, `text <1.3`, `time <1.10`
          bounds are stale on GHC 9.12; `doJailbreak` in
          `flake.nix`'s `hnvrHaskellOverlay` lifts them.

    75. **NoFieldSelectors pitfall generalised** (Aug 11 2026 M1,
         extends pitfall #46) — `rec.field` is the ONLY access form
         inside hnvr-web library modules (NoFieldSelectors is in the
         library default-extensions). This applies to BOTH reads
         (`sup.csConfig`) AND writes via record-update in module-
         qualified positions. The trap fires whenever you write a new
         module in hnvr-web with the standard extension set. Watch for
         `[GHC-88464] Variable not in scope: <fieldSelector> ::
         <Type> -> <FieldType> Suggested fix: Notice that '<field>' is
         a field selector belonging to the type '<Type>' that has been
         suppressed by NoFieldSelectors.` Fix: switch `f x` → `x.f`.
         Add `{-# LANGUAGE OverloadedRecordDot #-}` to the module if
         it's not already there (it IS in hnvr-web.cabal
         default-extensions but module-local LANGUAGE pragmas can
         shadow).

    76. **hlint misparses OverloadedRecordDot `c.id` as composition**
         (Aug 11 2026 archive-browser) — `camUuid c = case c.id of ...`
         trips "Redundant id" (hlint sees `c . id`). Fix: use
         `case c |> get #id of Id u -> u` instead of record dot for
         `id` fields specifically; other field names are unaffected.

    77. **IHP `paramOrNothing` is PURE** (Aug 11 2026 archive-browser) —
         `paramOrNothing :: (?request :: Request) => ByteString -> Maybe Text`,
         not `IO (Maybe Text)`. Bind with `let`, not `<-`. Ideal for
         optional query params when AutoRoute only handles the typed
         constructor fields.

    78. **Never edit an already-applied migration file** (Aug 11 2026) —
         m3-m8 appended the BRIN index to `migrations/0001-initial.sql`
         AFTER dev DBs had applied it → `schema_migrations` checksum
         mismatch → leader refuses to boot with the cryptic error
         `SchemaMigration 0001-initial failed: "0001-initial"`. Fixed by
         restoring 0001 to its applied checksum and moving the index to
         `0002-brin-index.sql` (+ a second `MigrationScript` in
         `SchemaMigration.runLeaderMigrations`). Policy (already written
         in the file header, now enforced by pain): new schema change =
         new `NNNN-name.sql` + new embed + new runMigration call.

    79. **Headless `devenv up` needs a pseudo-TTY** (Aug 11 2026) —
         `devenv up --detach` does NOT exist (process-compose prints its
         own usage and exits); `nohup … devenv up` dies with
         `TUI startup error: open /dev/tty`. Working headless form:
         `nohup script -qec "nix develop --no-pure-eval --command devenv up" /tmp/pc.log &`.

    80. **Playwright strict mode + hidden form inputs** (Aug 11 2026) —
         `locator('input[name="from"]')` matches BOTH the filter-form
         datetime input AND the hidden inputs in per-row delete forms →
         strict-mode violation. Scope form assertions to
         `page.locator('form[action="/Archive"] …')` whenever a page
         carries more than one form.

    81. **Timeline grouping must partition by camera** (Aug 11 2026) —
         `groupRecordings` on a mixed-camera segment list merged all
         three cameras into a handful of cross-camera "recordings"
         (concurrent captures interleave at sub-second offsets, far
         below the 30s split tolerance). Symptom: /Archive showed 4
         rows all labeled low_ent instead of ~12 across 3 cameras.
         `Hnvr.Core.Recording.Span` now carries `spCameraId` and
         grouping is `groupRecordingsBy spCameraId`. Any future
         timeline/density logic has the same constraint.

    82. **IHP AutoRoute maps `Delete*` constructors to HTTP DELETE
         only** (Aug 12 2026) — `DeleteRecordingAction` 405'd our plain
         `<form method="POST">` with `UnexpectedMethodException
         {allowedMethods = [DELETE]}`. IHP's own delete forms rely on
         ihp.js's method-override helper, which our custom Layout.hs
         doesn't load; there is no `_method` middleware in v1.6.0.
         Workaround: name destructive POST actions without the `Delete`
         prefix (`PurgeRecordingAction`, same pattern as
         `AssignCameraAction`).

    83. **`nix build` overwrites `./result` with the LAST-built attr**
         (Aug 12 2026) — running `nix build .#checks…pre-commit` after
         `.#hnvr-web` replaced `./result` with the pre-commit-run
         output, and the next leader restart died with
         `result/bin/hnvr-leader: No such file or directory`. Use a
         dedicated out-link for the app: `nix build .#hnvr-web -o
         result-web` and run `./result-web/bin/hnvr-leader`.

    84. **S3 row-key deletes are blind to legacy/orphan objects**
         (Aug 12 2026) — rows written before the ms-key fix store
         second-precision keys while the objects are ms-precision, and
         S3 DELETE of a nonexistent key silently succeeds. Purging
         via DB keys alone orphaned ~9.8k objects (4.2 GB) and wedged
         dev MinIO at its free-drive threshold (`XMinioStorageFull`).
         `PurgeRecordingAction` now also lists `<slug>/<date>/` per day
         in the window and deletes by key-embedded timestamp
         (`parseKeyTimestamp`), independent of the rows. `init.mp4`
         never matches the segment layout and is deliberately kept.
         Companion dev fix: `HNVR_SPOOL_DIR` is now set in the devenv
         env block — NodeMain's `/var/lib/hnvr/spool` default is
         unwritable outside NixOS, so the spool fallback had been
         silently failing in dev.

    85. **IHP AutoRoute field names share the URL param namespace with
        filters** (Aug 12 2026) — `PurgeRecordingAction {cameraId :: Id
        Camera}` made IHP generate URLs like `/PurgeRecording?cameraId=…`.
        The archive browser also round-trips a `cameraId` *filter* param
        through the same URL (so the post-delete redirect can land back
        on the same filtered view). With both names colliding we got
        `?cameraId=X&cameraId=X` — Sergey caught it in DevTools.
        Workaround: rename the AutoRoute field to a verb-prefixed name
        (`purgeCameraId`) so the filter name has its own slot. Same trap
        applies to any controller action that round-trips filter params
        through its own URL — keep action-field names distinct from
        filter param names. Same pattern was already used for
        `from`/`to` (form body `purgeFrom`/`purgeTo` vs URL filter
        `from`/`to`).

    86. **systemd default `LimitNOFILE=1024` is too low for the leader**
        (Aug 12 2026) — under Sergey's 3-camera 24/7 capture load the
        leader holds many concurrent FDs: per-camera ffmpeg subprocess
        pipes, MinIO upload sockets, WHEP/WebRTC session sockets, async
        S3-purge workers (`PurgeRecordingAction` walks thousands of
        segment keys). It peaked past 1024 and
        `Network.Socket.accept: resource exhausted (Too many open files)`
        started refusing new connections — `/NewSession` got `EAGAIN`,
        Playwright's `page.goto` retried for 30 s, the cameras-crud
        test looked "hung on login". Sergey's interactive shell has
        `ulimit -n 524288` so he never hit it; the systemd unit
        inherited the 1024 default. Fix: `nix/module.nix` sets
        `serviceConfig.LimitNOFILE = 524288;`. Symptom signature: a
        test that times out on `page.goto` while `curl localhost:port`
        from the same shell works fine — check
        `journalctl ... | grep "resource exhausted"`.

    87. **`deleteRecords` issues N round-trips, not a bulk DELETE**
        (Aug 12 2026) — IHP's `deleteRecords :: [record] -> IO ()`
        loops one SQL DELETE per record. For Sergey's 2h+ recordings
        (8k+ segment rows) that's 8k round-trips, each acquiring a
        pooled connection. Under load this contended with concurrent
        requests enough to slow the cameras-crud login lookup past its
        Playwright timeout. Bulk form for windows of N>100 rows:
        ```haskell
        _ <- sqlExec
          "DELETE FROM segments WHERE camera_id = ? AND end_ts > ? AND start_ts <= ?"
          (cameraUuid, from, to)
        ```
        Plain DELETE is DML — `sqlExec` works fine (the pitfall #42
        breakage is DDL-only). The trade-off: you lose IHP's
        per-record `beforeDelete`/`afterDelete` hooks, which we don't
        use anyway.

    88. **`Async.async` for destructive actions: capture `?modelContext`
        explicitly** (Aug 12 2026) — `PurgeRecordingAction` walks
        thousands of S3 keys; doing it in the request thread made the
        form POST "keep pending forever" (Sergey's words). Pattern for
        spawning the work into a background thread while keeping DB
        access:
        ```haskell
        let mc = ?modelContext
        _ <- liftIO $ Async.async $
          let ?modelContext = mc
           in purgeRecordingInBackground camera cid from to
        ```
        `ModelContext` is a connection pool — safe to share across
        threads. `?context` (ControllerContext) is request-scoped and
        must NOT be captured into a long-lived thread (it carries the
        current request's response handles). The async worker wraps
        its body in `E.handle (\(e :: SomeException) -> …)` so a
        transient S3 hiccup doesn't crash the leader; RetentionSweeper
        is the canonical convergence path for any leftover S3 state.

    89. **ORT `CreateSession` takes `OrtEnv*` as its FIRST arg** (Aug 12
        2026, Phase 3 slice 1) — signature is
        `CreateSession(env, model_path, options, out)`, NOT
        `(model_path, options, out)`. Omitting env segfaults inside
        `OrtApis::CreateSession` (interprets the path CString as an
        env pointer). Caught via gdb backtrace: versionString smoke
        test passed but CreateSession crashed. Debugging recipe:
        `nix shell nixpkgs#gdb --command gdb -batch -ex run -ex bt <bin>`.

    90. **ONNX Runtime vtable indices are version-locked** (Aug 12 2026)
        — `Hnvr.Cv.OnnxRuntime.Internal`'s `idx*` constants were
        generated by parsing `struct OrtApi` from
        `onnxruntime_c_api.h` of the PINNED nixpkgs onnxruntime
        (1.24.4, ORT_API_VERSION 24). ~415 entries, split-by-`;` then
        match `ORT_API2_STATUS/ORT_API_T/ORT_CLASS_RELEASE/(ORT_API_CALL*`.
        Bumping the nixpkgs onnxruntime version = regenerate indices
        FIRST (stale indices are silent memory corruption, not compile
        errors). The python one-liner is in git history (Phase 3
        slice 1 session). Note `GetVersionString`/`GetApi` live on
        `OrtApiBase` (indices 0/1 there), not the OrtApi vtable.

    91. **hnvr-cv smoke tests gate on `HNVR_ONNXRUNTIME_LIB`** (Aug 12
        2026) — absolute path to `libonnxruntime.so` (e.g.
        `/nix/store/…-onnxruntime-1.24.4/lib/libonnxruntime.so`). Same
        skip-silently pattern as `HNVR_TEST_INTEGRATION`. Same env var
        is read by `loadApi` at runtime, so dev/NixOS wiring just sets
        it to the nixpkgs package output. nixpkgs onnxruntime 1.24.4
        is CPU-only by default (`cudaSupport ? false`); the CUDA/TRT
        EP append path is written but untested until we override with
        `cudaSupport = true` — sessions fall through to CPU cleanly
        (verified in the smoke test's fallback assertion).

    92. **massiv `Ix3` is EXACTLY 3 dimensions** (Aug 12 2026, Phase 3
        slice 2) — the design doc's `Array S B (Ix3 1 3 320 320)` is
        aspirational; a 4-dim NCHW tensor needs `Ix4`. Indexing
        pattern for Ix4 is `0 :> c :> y :. x` — `:>` (from
        `IxN ((:>))`) prepends all but the last two dims, `:.` (from
        `Ix2 ((:.))`) terminates. `Sz4` used as a pattern needs
        `pattern Sz4` in the import list (+ PatternSynonyms pragma);
        `S` needs `S (S)`; `makeArray` results want a
        `:: Array D Ix4 Float` annotation or `computeAs` ambiguity
        bites. Sergey's model cache lives at
        `~/.local/share/hnvr/model_cache` (yolov7 `.trt` engines +
        facedet/paddleocr/license-plate ONNX — NO yolov8n-320 yet;
        reconcile at AnalyzerWorker slice).

    93. **ORT `CastTypeInfoToTensorInfo` output is NOT caller-owned**
        (Aug 12 2026, Phase 3 slice 5) — header says "Do not free this
        value, it will be valid until type_info is freed". Releasing
        it AND the OrtTypeInfo double-frees (`free(): double free
        detected in tcache 2` at process exit). Contrast with
        `GetTensorTypeAndShape` (on an OrtValue) whose output IS
        caller-owned. Read dims while the TypeInfo is alive, release
        only the TypeInfo.

    94. **cabal repl + dlopen = SIGABRT** (Aug 12 2026) — probing
        models via `cabal repl hnvr-cv` + `withSession` dies with
        exit code -6 (ghci dynamic-loading vs dlopen'd libonnxruntime).
        Compiled test binaries are fine. Model probing recipe: set
        `HNVR_ONNXRUNTIME_LIB` + `HNVR_TEST_MODEL` and run
        `cabal test hnvr-cv` — the gated AnalyzerSpec prints
        `HNVR_TEST_MODEL probe: input=… output=…` to stderr.

    95. **Model cache probed Aug 12 2026** — no YOLOv8-format model in
        `~/.local/share/hnvr/model_cache`:
        `facedet.onnx` = `[1,3,640,640] → [1,6400,1]`;
        `yolov9-256-license-plates.onnx` = `[1,3,256,256] → [-1,7]`
        (post-NMS). Pipeline integration test (`HNVR_TEST_MODEL`)
        needs a real `yolov8n-320.onnx` (`[1,3,320,320] → [1,84,2100]`)
        — pending Sergey's ultralytics export.

    96. **ORT C API argument-order traps** (Aug 12 2026) —
        `Run(…, output_names, output_names_len, outputs)`: the
        output_names_len comes BEFORE the outputs pointer (swapped =
        garbage span length → SIGSEGV inside `InferenceSession::Run`).
        And `CreateTensorWithDataAsOrtValue`'s `p_data_len` is BYTES,
        not elements ("not enough space: expected 1228800, got
        307200"). Both caught by the first real-model gated test.

    97. **ultralytics in the devShell (Aug 12 2026)** — top-level
        `pkgs.ultralytics` omits the optional ONNX export deps
        (`import onnx` fails mid-export). devenv wires
        `python3.withPackages [ultralytics onnx onnxslim]` (8.4.x
        uses onnxslim, not the old onnxsim). AGPL-3.0 — export tool
        only, never in NixOS closures. Multi-GB torch closure on
        first `nix develop`. Verified exports:
        ```bash
        yolo export model=yolov8n.pt format=onnx imgsz=320 opset=17 simplify=True dynamic=False
        yolo export model=yolov8s.pt format=onnx imgsz=640 opset=17 simplify=True dynamic=False
        ```
        installed at `~/.local/share/hnvr/model_cache/yolov8/
        {yolov8n-320,yolov8s-640}.onnx`. Probes: n-320 =
        `[1,3,320,320]→[1,84,2100]`, s-640 = `[1,3,640,640]→[1,84,8400]`.
        Real-frame validation: cam-197 sub-stream raw frame (720×480,
        `ffmpeg -pix_fmt rgb24 -f rawvideo`) through analyzeFrame →
        person detection at conf 0.10 (suppressed at default 0.35,
        visible via HNVR_TEST_FRAME=path:WxH gated probe). CPU
        inference ~80 ms/frame vs design's ~10 ms target — CPU EP on
        this box is slower than design's i7-12700 estimate; CUDA/TRT
        EP will matter.

    98. **`nixpkgs#attr` via registry ≠ flake's pinned
        `inputs.nixpkgs`** (Aug 12 2026) — the ORT vtable indices were
        first generated from the CHANNEL's onnxruntime 1.24.4 while
        the project's pinned nixpkgs ships 1.27.1. Caught when devenv
        wired `HNVR_ONNXRUNTIME_LIB = ${pkgs.onnxruntime}/…` and the
        versionString test reported 1.27.1. ORT's append-only ABI
        saved us: every index we use is identical across 1.24.4→1.27.1
        (verified by re-parsing the 1.27.1 header from the `-dev`
        store output — `/nix/store/*-onnxruntime-V-dev/include/
        onnxruntime/onnxruntime_c_api.h`). Rule: for anything the
        flake builds against, parse headers from
        `github:NixOS/nixpkgs/<flake.lock rev>#<pkg>.src` or the
        store `-dev` output, never the channel. `ortApiVersion` is
        now 27; the versionString test asserts only the "1." prefix
        (nixpkgs bumps minors regularly).

    99. **ORT output slots must be zeroed before `Run`** (Aug 12 2026,
        the 4-hour leader SIGSEGV hunt) — `alloca $ \outValOut`
        leaves stack garbage in the slot; ORT's contract is
        `output[i] == NULL` → ORT allocates the output OrtValue.
        Non-null garbage → ORT copy-constructs from a garbage
        `OrtValue*` → `mov (%r14),%rax` on packed-small-int junk
        (`0x6800000053`-style) inside `InferenceSession::Run`.
        **Symptom signature: passes all isolated stress tests (fresh
        native stacks read as zero), crashes in the long-lived leader
        (reused stacks carry non-null junk).** Fix: `poke outValOut
        nullPtr` before the Run call. Forensics path that worked:
        `coredumpctl debug <pid>` (systemd-coredump captures cores
        even for setsid'd processes) → faulting addr pattern → match
        the crashing loop to ORT source
        (`inference_session.cc` span-Run fetch loop). Also: ORT
        `CreateTensorWithDataAsOrtValue` DOES copy the shape dims
        (TensorShape ctor), and `VS.unsafeWith` liveness must wrap
        the whole create+Run, not just creation.

    100. **Shell traps that ate hours of debugging** (Aug 12 2026):
        - `pkill -f "bin/hnvr-leader"` matches the INVOKING SHELL's
          own `zsh -c` command line → kills your own command chain
          silently. Use `pkill -f "bin/hnvr-lead[e]r"`. Aug 13 2026
          addendum: the `[e]` trick does NOT save you if the same
          compound command ALSO contains the literal string
          `bin/hnvr-leader` (e.g. `pkill …; setsid ./result-web/bin/
          hnvr-leader …`) — the regex matches the restart half of
          your own cmdline. Run pkill in its own tool call, start in
          the next.
        - `grep -c pattern` exits 1 on zero matches → `cmd && grep -c
          x && next` silently skips `next`. Append `|| true` or use
          `if` guards.
        - `nix log` output has ANSI color codes → `grep "error"`
          misses colored diagnostics; errors mid-log (parallel cabal
          continues compiling other modules past a failure) — read
          the FULL log, not just the tail.
        - Backgrounding via `nix develop --command bash -c '… &'`
          gets reaped when the session exits; use `setsid … &
          disown`. And nix develop eval on a dirty tree now takes
          ~90 s — for rapid leader restarts, export the env vars
          directly (see /tmp/opencode/leader-env.sh pattern) and skip
          nix develop entirely.

    101. **ekg-core `Distribution` min/max are garbage under `-N`**
         (Aug 13 2026, Phase 3 EKG slice) — the store is 8 striped
         `Distrib`s keyed by capability; `read`/`sampleAll` folds them
         via `combine`, which copies `minPos`/`maxPos` from the LAST
         stripe unconditionally (untouched stripes stay 0.0). With
         `-N`, `_max` renders as 0.0 while count/sum are correct.
         `Hnvr.Core.Metrics.renderPrometheus` therefore emits only
         `_count` + `_sum` for distributions (avg latency =
         rate(sum)/rate(count) — the Prometheus-idiomatic shape).
         Also: ekg metric names are arbitrary Text — we embed
         Prometheus label sets directly in the name
         (`hnvr_frames_decoded_total{camera="floor_2_5"}`) and the
         renderer splits at the first `{` when adding suffixes.

    102. **Metrics endpoint is its own warp, NOT IHP middleware**
         (Aug 13 2026) — `Hnvr.Web.Metrics.startMetricsServer` runs on
         `HNVR_METRICS_PORT` (default 9100) in BOTH hnvr-leader and
         hnvr-node (node has no IHP chain to hang it on; also avoids
         the pitfall-#60 first-write-wins `option` trap). Dev port is
         9102 because devenv MinIO owns :9100 — devenv env block sets
         it. `CaptureConfig.capMetrics :: Hnvr.Core.Metrics.Metrics`
         (record of IO actions) is the seam: hnvr-capture/hnvr-cv
         stay ekg-free, hnvr-web backs the actions with an ekg-core
         `Store`. ekg-core errors on duplicate registration — the
         per-camera/per-EP metric caches in `Hnvr.Web.Metrics.newMetrics`
         are load-bearing, don't "simplify" them away.

    103. **cuDNN ≥ 9.12 dropped Maxwell/Pascal — Pascal GPUs can't run
         nixpkgs' ORT CUDA EP** (Aug 13 2026) — two separate support
         windows: nvcc 12.9 still emits sm_61 SASS (nixpkgs _cuda db
         `maxCudaMajorMinorVersion = "12.9"`; 13.x drops it), BUT
         cuDNN 9.12+ requires CC ≥ 7.5 (nixpkgs marks cudnn 9.22
         `badPlatforms x86_64-linux` when `cudaCapabilities` contains
         6.1 — an EVAL-time error, and it's a real runtime removal,
         not just metadata). ORT 1.27's CUDA EP links cuDNN
         unconditionally (`onnxruntime_providers_cuda.cmake` —
         `include(cudnn_frontend)` + `CUDNN::cudnn_all`); the old
         `onnxruntime_USE_CUDNN` option is gone. Only cudnn-less knob
         is `onnxruntime_CUDA_MINIMAL` (cudart only, guts kernels).
         Decision: hnvr-1 (GTX 1070) runs CPU EP in v1. Also:
         overriding away a `badPlatforms` dep via
         `overrideAttrs (old: { buildInputs = filter … })` does NOT
         work when the expression interpolates `${cudaPackages.cudnn}`
         into cmakeFlags — touching old.cmakeFlags forces the string
         → instantiates cudnn → badPlatforms throws anyway.

    104. **ORT's TRT EP + nixpkgs `FETCHCONTENT_FULLY_DISCONNECTED`**
         (Aug 13 2026) — with `onnxruntime_USE_TENSORRT=ON` and the
         default parser path, ORT FetchContent's the `onnx-tensorrt`
         repo to build `nvonnxparser_static` from source. nixpkgs sets
         FULLY_DISCONNECTED and wires no
         `FETCHCONTENT_SOURCE_DIR_ONNX_TENSORRT`, so the target is
         silently missing and the link dies with
         `cannot find -lnvonnxparser_static`. Fix:
         `-Donnxruntime_USE_TENSORRT_BUILTIN_PARSER=ON` — links TRT's
         own `libnvonnxparser.so` from the redist instead of building
         anything. Also: nixpkgs splits tensorrt into
         out/include/lib/static — ORT's cmake wants one TENSORRT_ROOT
         prefix; symlinkJoin the outputs. TRT redist is
         `meta.insecure` → `permittedInsecurePackages` (compute the
         name dynamically like minioVersion — hardcoding
         `cuda12.9-tensorrt-10.14.1.48` breaks on the next nixpkgs
         bump).

    105. **Lazy pure-state threading in a forever-loop = linear heap         leak** (Aug 13 2026, the leader OOM) — `Sort.update` is a
         pure lazy function; `analyzeFrame` stored its result in the
         analyzer record UNFORCED. Nothing ever forced it in
         production (the leader's TVar sink stores `tracks` lazily),
         so one unevaluated `update` application accumulated per
         frame, each closure retaining the frame's detection pipeline
         (inSource → letterbox geometry → the input Frame) —
         ~one full frame per frame (~80 MB/s at 2×15 fps 1280×720;
         kernel OOM at ~64 GB swapped in 45 min). **Slice-7's bake
         passed only because open debug streams forced `tracks` every
         frame.** Diagnosis path that worked: `+RTS -M4G` (dies fast
         ⇒ GHC heap, not native), then bisect via
         `hnvr-cv/app/LeakProbe.hs` stages
         (preprocess|infer|decode|full|fulllazy|notracks), then
         profiling build (`--enable-profiling` works for hnvr-cv —
         no IHP in its dep cone) with `-hT` (ARR_WORDS dominance ⇒
         retained vectors, not thunk metadata) and `-hc`. Fix is
         two-part: (1) `Sort.update` internally forceTracks
         (IM.foldl' + per-track field seqs — IntMap is spine-strict
         but VALUE-lazy), (2) `analyzeFrame` `evaluate tracker'` —
         seq inside update only runs once the application is forced;
         the loop head must pull the trigger. Companion gotcha:
         `pgrep -f` matched my own wrapper shell when the command
         line contained the plain binary name inside a `find -name`
         argument — RSS "measurements" of a dead process looked
         alive. And `Heap exhausted` under `-M` does NOT necessarily
         kill a multi-threaded GHC process — the zombie kept serving
         :18001/:9102 with analysis threads dead; later leaders then
         die on `bind: Address already in use`.          Check `lstart` of the
         port owner before trusting restart logs.

    106. **Not every RSS climb is a leak — measure first** (Aug 14
         2026, "leader leaks again" investigation) — the leader showed
         sustained native growth to ~2.8 GB that CONVERGED, not a
         leak. Discrimination recipe: (1) `+RTS -M4G` — GHC-heap leaks
         die "Heap exhausted" in minutes, native/plateau growth sails
         on; (2) `+RTS -S` — the live-bytes column after each GC
         (ours: 10–16 MB live ⇒ Haskell heap clean); (3) ORT-only
         repro via LeakProbe (flat ⇒ native libs clean); (4) bisect
         envs (analysis off = 850 MB flat ⇒ analysis-path working
         set). The actual baseline driver: executables carried
         `-A64m -I0` (copied from a test suite) — 64 MB nursery × 32
         capabilities ≈ 2 GB of arenas. Now `-A16m` (~500 MB). Final
         working set at yolov8s-640/TRT/3 cams ≈ 2.3 GB flat over
         15 min (≈1 GB TRT contexts, rest IHP+RTS). New gauge:
          `hnvr_process_resident_bytes` (read from /proc/self/statm by
          the metrics poller every 15 s) — watch the bake on /metrics
          instead of eyeballing `top`.

    107. **`catch`/`try SomeException` swallows cancellation** (Aug 14
         2026, Phase 3 close-out) — `frameSourceLoop` caught
         `SomeException` around `runFrameSource`, so `cancel` on the
         source async delivered `AsyncCancelled`, the loop logged it
         as a transient error and RESPAWNED ffmpeg; `cancel` then
         blocked forever waiting for the thread to die (deadlock on
         camera stop). Same latent pattern in `Worker.transition`'s
         runOnce catch (stop → respawn loop), `handleFragment` and
         `storeOrUpload`. Fix pattern everywhere:
         ```haskell
         `catch` \(e :: SomeException) -> do
           case fromException e of
             Just (SomeAsyncException _) -> throwIO e  -- needs SomeAsyncException(..) import
             Nothing -> pure ()
           ...sync-error handling...
         ```
         `System.Timeout.timeout`'s exception also arrives
         async-wrapped, so a SomeException catch silently defeats
         `timeout` bounds too (this is why the SpoolDrainer test's
         5 s bound did nothing before the fix). `ConfigBroadcaster` /
         `MediaMTXConfigSyncer` / `SnapshotResponder` catches not yet
         audited — check them next time they're touched.

    108. **minio-hs retries connection-refused forever** (Aug 14 2026)
         — `putObjectBytes` against a dead endpoint
         (`http://127.0.0.1:1`) never returns: minio-hs's retry policy
         covers connect failures, not just 5xx. Consequence 1: tests
         that exercise S3-failure paths must bound the call with
         `timeout` (works only post-pitfall-#107 fix). Consequence 2:
         `drainOnce` against a long-dead S3 sits inside one upload
         retry loop rather than cycling files — acceptable (next pass
         re-lists anyway), but don't expect a drain pass to terminate
         during a full outage.

    109. **IHP schema-compiler rejects `--` comments inside CREATE
         TABLE column lists** (Aug 14 2026) — `nix run …#schema-compiler`
         fails with `unexpected "-- per-"` when a comment sits between
         column definitions. Keep comments outside the table body
         (above the CREATE TABLE) or regen.sh dies mid-run leaving
         gen/ deleted (it does `rm -rf gen` first — rerun after fixing
         to restore).

    110. **Node snapshot request races leader boot** (Aug 15 2026) —
         a node that boots before the leader's SnapshotResponder is
         subscribed gets no reply and logs "will rely on assign
         messages" — but AssignmentCoordinator only publishes ON
         CHANGE, so the node runs camera-less until something
         reassigns or the node restarts. No periodic retry exists.
         **FIXED (Aug 15 2026, v0.4.0.1): NodeMain's `claimHost`
         retries the snapshot request every 30 s until granted, and
         the ConfigWatcher only starts after the grant.**

    117. **Never run hnvr-node on the leader host** (Aug 15 2026, the
         1–2 s playback jump-back bug) — the leader binary embeds the
         full node role (`Config.startNodeRoles`), so a stray node
         with the same `HNVR_HOST` double-records every camera: two
         RTSP sessions, duplicate fragment uploads with object keys
         1–5 ms apart, and the archive playlist (`orderByAsc startTs`)
         serves each second of video twice → the player visibly jumps
         back at every seam, deterministic per recording. The 2×
         session count can also push consumer cams past their RTSP
         session cap (pitfall #11), glitching the mediamtx source
         session = the "live" jumps. Guard: snapshot-claim handshake
         (`Hnvr.Core.HostClaim` + `csbClaimed`); a denied node idles
         worker-less. Diag: `SELECT object_key, count(*) FROM segments
         GROUP BY 1 HAVING count(*) > 1` — any rows = duplicate
         recorder somewhere.

    118. **minio-hs `executeRequest` never validates HTTP status**
         (Aug 15 2026) — `httpLbs` only throws on connection errors,
         so any 4xx/5xx response is returned as "success". Anything
         that parses the body (list/put/stat) fails loudly downstream,
         but `deleteObject` did `void $ executeRequest …` → failed
         DELETEs were SILENT no-ops (retention sweeps appearing to
         "not clear S3"). Patched in the vendored copy: 2xx + 404 = ok,
         else throw `ServiceErr`. Related trap while debugging this:
         heredoc ghci without `-XOverloadedStrings` type-errors the
         string-literal line but still runs the remaining lines —
         "DELETE_DONE" printed for a delete that never typechecked.
         Verify library claims against `mc stat` / `mc admin trace`,
         not against your own printf.

    110. **Presigned S3 URLs are signed for the endpoint host** (Aug 14
         2026) — archive playlists and event thumbnails leaked
         `http://localhost:9100` to external browsers because presigning
         used the internal `HNVR_S3_ENDPOINT`; the SigV4 host header is
         part of the signature, so string-rewriting the URL after
         presign invalidates it. Fix: `S3Config.s3cPublicEndpoint` +
         `HNVR_S3_PUBLIC_ENDPOINT`; server-side put/list/delete use
         `connectInfo`, browser presigns use `presignGetUrlWithConfig` /
         `presignConnectInfo`. NixOS module option:
         `services.hnvr.leader.s3PublicEndpoint`.

    111. **Overlay components + `hidden` attribute** (Aug 15 2026, UI
         v2) — author CSS `display: flex` on `.live-overlay`/`.lightbox`
         beats the UA's `[hidden] { display: none }`, so a "hidden"
         overlay invisibly covers the page and intercepts every click
         (Playwright: "subtree intercepts pointer events"). Fix shipped
         in src.css base layer: `[hidden] { display: none !important }`.

    112. **HSX allows `data-*` / `aria-*` attributes** (Aug 15 2026) —
         pitfall #43's whitelist has explicit prefixes: any attribute
         starting `data-`, `aria-`, `hx-` parses. All app.js hooks are
         `data-*`. Also: app.js must load WITHOUT `defer` in <head> —
         body-level inline scripts (pitfall #63 splices) run BEFORE
         deferred scripts, so `HNVR.whep` would be undefined.

    113. **hlint flags `coerce h.id` as "Redundant id"** (Aug 15 2026,
         extends pitfall #76) — in a where-binding `x = coerce h.id ::
         Text`, hlint parses `h.id` as composition. Fix: `case h |> get
         #id of Id t -> t` with `import IHP.ModelSupport (Id' (Id))`.
         Also: pre-commit end-of-file-fixer rewrites the minified
         `static/app.css` (no trailing newline) — excluded in flake.nix
         preCommit hooks (`^hnvr-web/static/app\.css$`).

    114. **backyard + low_ent WHEP return 400 in headless chromium**
         (Aug 15 2026) — floor_2_5 live view works (201, "Live");
         backyard and low_ent fail `WHEP POST ... 400` on BOTH /ShowLive
         and the dashboard overlay, i.e. camera/mediamtx-side, not UI.
         Not root-caused (possibly HEVC paths or stale mediamtx config).
         Check `/v3/config/paths/get/<slug>` when touching live view.

    115. **Stale `./result` leader + new app.css = broken mixed layout**
         (Aug 15 2026, Sergey's "body shifted right" report) — a leader
         started from `./result/bin/hnvr-leader` (pre-redesign binary,
         Aug 14 store path) served OLD HTML while the dev server reads
         `APP_STATIC=hnvr-web/static` from CWD = NEW app.css. Old
         `.shell` was flex-column+topnav, new CSS is flex-row → the
         page body rendered as a row item to the right of the unstyled
         nav strip. Not a CSS bug. Rule: after ANY UI rebuild, the dev
         leader must be restarted from `./result-web/bin/hnvr-leader`
         (never `./result` — pitfall #83's overwrite trap), and
         `pgrep -af 'hnvr-lead[e]r'` must show exactly one process
         before trusting what the browser shows.

116. **minio-hs `continuation_token` typo = infinite listing loop**
         (Aug 15 2026, the 13→47 GB leader OOM) — see the dedicated
         block at the top of this file. Core lessons: (1) a "memory
         leak" with GHC live-bytes flat but RSS linear is foreign/
         pinned accumulation — but here even live-bytes doubled each
         second because sinkList's accumulation IS heap; `-M4G -S` +
         env kill-switch bisect found PendingPurge in six 100-s runs.
         (2) `listObjectKeys` now has a strictly-increasing-key sink
         guard. (3) Never trust `nix build … | tail; echo $?` — pipe
         exit codes; verify freshness via `strings binary | grep
         marker`.

> **minio-hs pagination OOM (Aug 15 2026, evening — the 13→47 GB
> leak)**: minio-hs 1.7.0 `listObjects'` sends `continuation_token`
> (underscore) where S3 ListObjectsV2 requires `continuation-token`
> (hyphen). MinIO ignores it → every paginated listing re-fetches
> page 1 forever → `CC.sinkList` accumulates unboundedly (~30 MB/s,
> heap "live" doubling each second until `-M4G` exhaustion). ANY
> prefix with >1000 objects triggers it; yesterday's PendingPurge
> verification passed only because its windows listed <1 page. Fix:
> **vendored `vendored/minio-hs`** (in cabal.project `packages` +
> flake overlay via callCabal2nix) with the one-token patch PLUS the
> crypton-connection patches nixpkgs applies (commits 786cf188 +
> e2169892 — otherwise it needs `connection-0.3.1`, source-incompatible
> with tls 2.x). Plus a belt-and-braces guard in
> `Hnvr.Storage.S3.listObjectKeys`: the sink stops when keys stop
> strictly increasing (a repeated page restarts at a smaller key).
> Verified: listing floor_2_5's 7150-object day-prefix terminates
> correctly; the two stuck tombstone batches (91+288 rows) converged;
> leader flat ~2.2 GB RSS under full load. Leader also gained env kill
> switches for every background component (`HNVR_DISABLE_NODEROLES`,
> `_HEALTHREPORTER`, `_SNAPSHOTRESPONDER`, `_EVENTWRITER`,
> `_HEALTHCACHE`, `_COORDINATOR`, `_BROADCASTER`, `_MEDIAMTX`,
> `_RETENTION`, `_PENDINGPURGE`, `_METRICS`) in Hnvr.Web.Config —
> `gated` helper; used for the binary-search bisect (`-M4G -S`,
> 100 s runs: exhaust = leaking). **Bisect lesson: `cmd | tail -1;
> echo exit=$?` measures tail's exit code, not nix's — a stale
> `./result-web` cost three probe rounds; check `strings` for a fresh
> marker string instead.**

## Sergey's working style

- Direct, no hand-holding. Be concise.
- Prefers GHC 9.12 + IHP even though bleeding edge — accept the jailbreak cost.
- Uses `~/bin/env-wrap` for commands requiring project flake.nix/.envrc.
- Calls himself "Sergey" — never "user".
- Wants to design for horizontal scale even when v1 doesn't need it (hence
  NATS from day one).

## Roadmap status (Aug 12 2026 — archive-browser audit-fix landed)
- [x] **Archive browser/manager** (Aug 11 2026, audit-fixed Aug 12 2026) —
      `/Archive`: filter by camera/time-window (24h cap)/min-duration/
      slug-search, segments grouped into recordings (30s gap tolerance)
      via pure `Hnvr.Core.Recording` + `Hnvr.Core.Playlist`
      (cabal-tested, pitfall #14 extraction pattern); windowed playlist
      (from/to, ≤6h per design 05, default = last 1h ending at latest
      segment) fixing the oldest-3600-segments bug; player deep-links
      `?from&to&t` with hls.js startPosition; admin-gated
      DeleteRecording (S3 best-effort + rows). Prereq fix:
      `toSegmentWritten` now takes the ms-precision upload key as a
      param — DB object_key no longer diverges from the uploaded object
      (pitfall #25 class). Auth gate now covers ArchiveController (was:
      presigned URLs served unauthenticated).
      **Aug 12 2026 audit-fix** (commit `8bd8d1f`): three Sergey-reported
      bugs closed:
        * pageSize 25 → 10 — single-camera 24h window previously fit on
          one page, so the "1/1" pagination badge looked broken with 12
          visible rows.
        * Filter params (cameraId/from/to/q/minDuration/page) now
          round-trip through `PurgeRecordingAction`'s redirect via
          `browseQueryString` — was redirecting to bare `/Archive`,
          landing the user on the default window which read as "the
          deleted row is still there".
        * S3 purge moved to `Async.async` — `purgeObjects` walks
          thousands of keys sequentially; the synchronous request
          "kept pending forever". Pattern documented in pitfall #88.
      Two URL/payload name clashes surfaced + fixed (pitfall #85):
      `PurgeRecordingAction {cameraId}` → `{purgeCameraId}` (collided
      with the filter cameraId); form body `from`/`to` → `purgeFrom`/
      `purgeTo` (collided with the filter from/to).
      Performance + ops hardening: bulk `DELETE FROM segments WHERE …`
      replaced `deleteRecords` (pitfall #87); `LimitNOFILE=524288`
      added to `nix/module.nix` (pitfall #86 — systemd default 1024
      was too low).
      Pure extraction: `Hnvr.Core.ArchiveBrowser` (paginate,
      resolveBrowseWindow, browseQueryString, parseWhen) — 21 unit +
      3 property tests in `Hnvr.Core.ArchiveBrowserSpec`. Cabal tests
      now 143 total (97 in hnvr-core).
      Playwright `archive-browser.spec.ts` extended to 14 specs (was
      7): pageSize hard cap, "Next →" link + badge text, filter
      preserved in form action URL, hidden-input name-prefix contract,
      full delete round-trip with filter preservation, page param
      preserved on page >1. Total Playwright: 20 specs (19 active +
      1 skip gated on >10 recordings).

- [x] Design docs complete
- [x] Cabal scaffold + flake.nix
- [x] **Phase 0** — Bootstrap done. IHP wired, NATS bus implemented and
      connected at leader + node boot, `/healthz` returns 200, both NixOS
      VMs build and start their services, CI green for `nix build`.
- [~] **Phase 1** — Recording MVP. **Slice 1+2+3+4a+4b+4c+5+6+7a+7b done (Aug 9 2026)**:
      - ✅ Full recording pipeline verified end-to-end on Sergey's 3 cameras
      - ✅ IHP v1.6.0 schema + Cameras CRUD + ffprobe button
      - ✅ EventWriter (NATS → PG) + Archive playback (m3u8 + hls.js)
      - ✅ Slice 7a: `Hnvr.Core.Crypto` AES-256-GCM + sops-nix template
      - ✅ Slice 7b: Schema migrated `password TEXT` → `password_enc BYTEA`
            + `password_nonce BYTEA`. Cameras Create/Update encrypt on
            write via `Web.Controller.Support.Crypto` (renamed from
            `Hnvr.Web.Controller.*` in commit `ce739c1`, see pitfall #59);
            `UpdateCameraAction` skips re-encryption when the form's
            password field is blank (keep existing). Form labels updated
            to make this clear. Decrypt path (`decryptPassword`) is wired
            for `ProbeCameraAction` (deferred until rtsp_template
            rendering lands — currently rtsp_url already has creds
            embedded so Probe uses it directly).
      - ✅ Slice 8 (Aug 10 2026, phase-audit-fix): Cameras admin gate —
            IHP v1.6.0 `AuthSupport` wiring (`Hnvr.Web.Auth`,
            `Controller/Sessions.hs`, `View/Sessions.New.hs`),
            `users` table, `beforeAction = ensureIsUser` on
            `CamerasController`, `AuthMiddleware (authMiddleware @User)`
            in `Config.hs`, `seedAdminUser` initializer reads
            `INITIAL_ADMIN_EMAIL`/`INITIAL_ADMIN_PASSWORD` env, idempotent
            INSERT with `hashPassword` (pwstore-fast). Routes:
            `/NewSession`, `/CreateSession`, `/DeleteSession` (top-level,
            IHP AutoRoute default). Nav shows Login/Logout link. Closed
            audit-report-2 §2 row "Cameras CRUD admin gate".
      - ✅ Slice 9 (Aug 10 2026, phase-audit-fix): Probe sub-stream —
            `ProbeAction` now probes main URL + (when present) sub URL
            and persists `codec` (main) + `substreamCodec`/
            `substreamWidth`/`substreamHeight` (sub). Main-probe failure
            short-circuits; sub-probe failure logs but doesn't block
            main. EditView button relabeled "Probe Streams". Closed
            audit-report-2 §2 row "Probe sub-stream button".
- [~] **Phase 1 — Recording MVP.** Audit (Aug 11 2026,
      `.opencode/PHASE1_COMPLETION_MILESTONES.md`) found the previous
      "Phase 1 complete" claim overstated: no `CaptureSupervisor`
      existed, so nothing actually recorded in production. **M1 + M2
      landed Aug 11 2026** (this commit):
      - ✅ **M1 — CaptureSupervisor wiring.** New modules
            `Hnvr.Node.CaptureSupervisor` (per-worker async + stop TVar
            + idempotent start/stop/restart), `Hnvr.Web.CommandTypes`
            (`AssignPayload`/`ControlPayload` carrying full
            `CameraSnapshot` so receiving host spawns worker without
            extra round-trip), `Hnvr.Web.SnapshotResponder` (leader
            answers `hnvr.commands.snapshot.<host>` with current camera
            set; bridges the no-JetStream bootstrap problem),
            `Hnvr.Core.CameraSnapshot` (wire type for camera→worker
            config). `Bus.request`/`requestJson`/`reply` added to
            `Hnvr.Nats.Bus` (nats-queue has `Nats.request` but no
            timeout — wrapped with `System.Timeout.timeout`).
            `ConfigWatcher` now dispatches to CaptureSupervisor
            (start/stop/restart) instead of just logging.
            `AssignmentCoordinator.applyAssignment` projects Camera →
            CameraSnapshot via `projectCamera` and includes it in
            AssignPayload. NodeMain + LeaderMain (via Config.hs
            `startNodeRoles`) both spawn CaptureSupervisor, request
            initial snapshot from leader, and start workers for
            assigned cameras. Schema gained `rtsp_transport` column
            (default `'tcp'`) on `cameras` so the node knows whether
            to use `-rtsp_transport tcp` or `udp`.
      - ✅ **M2 — Versioned migrations via postgresql-simple-migration.**
            New module `Hnvr.Web.SchemaMigration` runs
            `MigrationInitialization` + `MigrationScript "0001-initial"`
            (embedded `Application/Schema.sql` via `file-embed`'s
            `embedFile`) inside a transaction at leader boot, BEFORE
            `IHP.Server.run`. Tracked in `schema_migrations` table so
            subsequent boots skip. `postgresql-simple-migration`
            jailbroken in `flake.nix` `hnvrHaskellOverlay` (0.1.15.0
            pins bytestring/text/time bounds that are stale on GHC
            9.12). `MigrationResult a` is parameterized by error type
            (`String` for init, `ByteString` for script) — `handleResult`
            is `Show a => String -> MigrationResult a -> IO ()`.
      - ✅ **M1+M2 integration test (verified Aug 11 2026):** all 3
            Sergey's cameras record continuously — 5633 segments in
            MinIO + matching rows in Postgres; mediamtx-as-single-
            puller architecture confirmed working (worker ffmpegs
            pull from rtsp://localhost:8554/<slug>, mediamtx holds
            single camera RTSP session, all 3 cameras' WHEP live
            view works concurrently with recording).
      - ✅ **M3-M7 (Aug 11 2026, post-M1 stability):**
          * M3 — `password_enc`/`password_nonce` decrypt path is now
            wired via `TestCryptoCameraAction` (POST endpoint + Show
            view "Test password decryption" button). Catches the
            silent HNVR_DATA_KEY rotation bug. Architectural reality:
            the mediamtx-as-single-puller change made the recording
            path's credential needs moot (worker pulls from local
            mediamtx, no creds), so password_enc stays as future-
            proofing for UI rotation/audit, not a hot-path concern.
          * M4 — sops-nix flake input uncommented, `nix/secrets.nix`
            module declares `services.hnvr.secrets.{enable,sopsFile,
            ageKeyFile}` + 8 sops.secrets.* entries. `nix/module.nix`
            preStart generates per-KEY systemd EnvironmentFile
            fragments from /run/secrets/* (sops writes one value per
            file; systemd wants KEY=value). Dev (devenv) unaffected —
            sops is opt-in via `services.hnvr.secrets.enable = true`.
          * M5 — `Hnvr.Capture.Ffmpeg.audioArgs` (the third ffmpeg per
            `03-capture-and-storage.md` §3). `Worker.runOnce` spawns
            it in parallel via `concurrently` when `ccRecordAudio=True`.
            Audio fragments use `.m4a` extension via new
            `formatSegmentObjectKeyMsExt` helper. NATS publish skipped
            for audio (no DB rows for v1; HLS audio group tagged for
            a future slice). Probe now does 2 ffprobe calls (v:0 + a:0)
            and populates `probeAudio`.
          * M6 — `Hnvr.Web.RetentionSweeper` hourly cron. Trust-the-DB
            sweep: queries `object_key` from `segments` past cutoff,
            deletes from S3 + Postgres in lockstep. Per-camera
            retention_days column drives the cutoff.
          * M7 — `Hnvr.Capture.SpoolDrainer` process-wide async
            started by CaptureSupervisor. 30 s drain interval, 60-
            file-per-camera cap (drops oldest), re-uploads spooled
            fragments to S3 when connectivity returns.
      - ✅ **M8 (Aug 11 2026):** doc cleanup — `design_docs/02-tech-stack.md`
            amazonka→minio-hs updated; HealthCache IORef-is-write-only
            Haddock corrected; migrations/0001-initial.sql gained the
            missing `segments_start_ts_brin` BRIN index from the design.
      - **Phase 1 — Recording MVP genuinely complete** (Aug 11 2026).
            M8 (doc cleanup) — see `.opencode/PHASE1_COMPLETION_MILESTONES.md`.
- [~] **Phase 2 — Live View + Multi-Host. Code complete (Aug 10 2026),
      live VM test pending**. Slices shipped:
      - ✅ Slice 1: `nix/mediamtx.nix` NixOS module + flake input.
            mediamtx bumped to v1.20.0 via `mediamtxOverlay` (Aug 10 2026) —
            matches design lock; previously nixpkgs 1.18.2.
      - ✅ Slice 2: `Hnvr.Web.MediaMTXConfigSyncer` — opens dedicated
            postgresql-simple connection for LISTEN `cameras_events`,
            regenerates `/run/hnvr/mediamtx.yml`, pushes per-path config
            to mediamtx REST API (`PUT /v2/config/paths/<slug>`).
            Trigger function installed idempotently at leader startup
            (no separate migration step).
      - ✅ Slice 3: `Hnvr.Web.WhepProxy` (WAI middleware, not an IHP
            controller — needs raw body + arbitrary methods). Path
            translation `/whep/<slug>` → `/<slug>/whep`, Location header
            rewritten back so the browser's PATCH/DELETE return to us.
            Live view (`/live/<slug>`) renders `<video>` + inline ~40-LOC
            vanilla-JS WHEP client (no npm).
      - ✅ Slice 4: `Hnvr.Node.HealthReporter` (5s heartbeat, payload
            mostly stubs — cameras list + EKG CPU/GPU/mem land in
            Phase 3+/Phase 6). `Hnvr.Web.HealthCache` subscribes
            `hnvr.health.>` → IORef + UPSERT into `hosts` table.
      - ✅ Slice 5: `Hnvr.Web.AssignmentCoordinator` — 5s poll,
            15s host-down timeout, `manual_assign=true` cameras never
            overridden, publishes `hnvr.commands.assign.<slug>` on
            change. **Slice 5 audit-fix (Aug 10 2026): also publishes
            `hnvr.commands.control.<old_host>.<slug>.stop` on cross-host
            reassignment for graceful drain.** `Hnvr.Node.ConfigWatcher`
            now subscribes three subjects: `hnvr.commands.assign.>`,
            `hnvr.commands.control.<this_host>.>`, and
            `hnvr.config.cameras.>` — all handlers decode + log;
            CaptureSupervisor dispatch lands in Phase 3.
      - ✅ Slice 6: `/` dashboard (camera grid + hosts table),
            `/hosts` per-host view, `POST /cameras/:id/assign` admin
            override (clears `manual_assign` when host field is blank).
      - **Aug 10 2026 audit-fix slice** (separate from Phase 2's
        original 1–6): closed the 8 spec/CI/tooling gaps from
        `.opencode/PHASE_AUDIT_REPORT.md`:
          * ✅ `Hnvr.Capture.Fmp4` parses `tfdt`, `MediaFragment`
                carries `baseMediaDecodeTime`; `Worker` uses wall-clock
                hold-back so `sEnd = next-fragment arrival`, not
                `sStart`.
          * ✅ `Hnvr.Web.ConfigBroadcaster` (new module) reuses
                `cameras_events` LISTEN and republishes camera row JSON
                on `hnvr.config.cameras.<slug>`; node-side
                `ConfigWatcher` subscribes.
          * ✅ `EventWriter` switched to raw SQL with
                `ON CONFLICT (camera_id, start_ts) DO NOTHING`
                (no more caught unique-violation noise).
          * ✅ Pre-commit `cabal-fmt` hook + `pkgs.mediamtx` in devShell
                + new `cabal-non-web` CI job (GHC 9.10 sanity commented).
      - nginx for WHEP **skipped** — WAI middleware handles it. nginx
            can land in Phase 6 as a public-facing layer if needed.
      - Open: WHEP not yet browser-tested; mediamtx REST push hasn't
             been exercised against a live mediamtx; AssignmentCoordinator
             load balancing is naive (lex-smallest host) — fine for 2
             hosts, real load-aware assignment deferred.
      - **Aug 10 2026 routing rename** (commits `ce739c1` + `87cd6c3`):
            controllers moved `Hnvr.Web.Controller.*` → `Web.Controller.*`
            and action constructors renamed to IHP-canonical per-resource
            form. See pitfall #59 for the IHP `actionPrefixText` gotcha.
            URL map now: `/` → dashboard (via `startPage DashboardAction`),
            `/Cameras` (list), `/ShowCamera?cameraId=…`, `/NewCamera`,
            `/EditCamera?cameraId=…`, `/CreateCamera`, `/UpdateCamera`,
            `/DeleteCamera`, `/ProbeCamera?cameraId=…`, `/AssignCamera`,
            `/PlayerArchive?cameraId=…`, `/PlaylistArchive?cameraId=…`,
            `/ShowLive?cameraId=…`, `/Hosts`, `/Dashboard`,
            `/NewSession`, `/CreateSession`, `/DeleteSession`. Views
            stayed under `Hnvr.Web.View.*` (only controllers moved).
      - **Aug 10 2026 Phase 2 blocker sweep** (closed 3 of 4 open items):
            * ✅ Taiga #467 closed — `MediaMTXConfigSyncer` migrated from
                  `/v2/config/paths/*` (gone in mediamtx v1.20) to
                  `/v3/config/paths/{list,add,patch,delete}`. See pitfall #61.
            * ✅ `/healthz` 404 fixed — root cause: two
                  `option $ CustomMiddleware` calls in `Config.hs` had only
                  the FIRST one active (IHP `option` is first-write-wins,
                  see pitfall #60). Fix: compose whep + healthz into one
                  `CustomMiddleware (whepMiddleware . healthzMiddleware)`.
            * ✅ WHEP `/whep/<slug>/session/<id>` path translation bug —
                  `WhepProxy.translatePath` was appending `/whep` at the
                  END instead of after the slug. Browser ICE-restart /
                  teardown (PATCH/DELETE on session URLs) now reaches
                  mediamtx correctly. See pitfall #62 for the middleware
                  composition order rule.
            * ✅ WHEP browser-tested end-to-end via curl probes (POST
                  `/whep/x` and PATCH `/whep/x/session/y` both reach
                  mediamtx; full SDP flow needs Sergey to verify in
                  Chrome against a live RTSP camera).
            Remaining: full Phase 2 demo (kill hnvr-1 → 15 s reassign)
            not yet exercised. AssignmentCoordinator load balancing
            still naive (lex-smallest host) — fine for 2 hosts.
- [x] **Test infrastructure (S1–S5 done Aug 11 2026)** — 94 Haskell
      tests + 6 Playwright specs + 1 NixOS VM smoke test. See
      "Test infrastructure (Aug 11 2026)" section above. The 5-sprint
      scope matches design_docs/10-test-plan.md v1.0 milestone exactly.
      Real bug found + fixed during S3: `WhepProxy.translateBack` was
      duplicating `/whep` in the middle of session URLs (latent
      throughout Phase 2 because pitfall #63 meant the WHEP JS never
      ran end-to-end). S6 (hnvr-cv tests) + S7 (hnvr-ptz tests) are
      gated on Phase 3 / Phase 5 implementation landing.
- [ ] **Phase 3 — CV detection + tracking. Slice 1 done (Aug 12 2026)**:
      `Hnvr.Cv.OnnxRuntime` + `Hnvr.Cv.OnnxRuntime.Internal` — internal
      FFI binding (dlopen + vtable, no Hackage dep) per locked design
      decision. `withSession` tries EPs in priority order
      (`SessionOptionsAppendExecutionProvider_{CUDA,TensorRT}_V2`), CPU
      fallback; `infer` wraps input in-place, copies output out. 2
      smoke tests env-gated on `HNVR_ONNXRUNTIME_LIB` pass against
      nixpkgs libonnxruntime 1.24.4 (CPU-only build). CI
      `cabal-test-non-web` now includes hnvr-cv. Open: no real model
      yet (yolov8n-320.onnx fetch/export is a later slice);
      cudaSupport override + TRT engine pre-build still pending.
      Next slices: Preprocess (massiv letterbox) → Decode/NMS →
      Tracker.Sort → AnalyzerWorker.
      **Slice 2 done (Aug 12 2026)**: `Hnvr.Core.Frame` (RGB24 storable
      frame type, producer/consumer seam between capture and cv) +
      `Hnvr.Cv.Preprocess` — `letterboxGeometry` (pure, property-pinned),
      `preprocessTo`/`preprocess` (bilinear letterbox → `Array S Ix4
      Float` 1×3×320×320, 114/255 pad), `toTensor` FFI adapter. 10 new
      tests (4 unit + 3 geometry + 3 properties — half-pixel rounding
      invariant + one-axis-fills + value range). hnvr-cv suite: 12
      tests total. Next slice: Decode (YOLOv8 [1,84,2100] anchor decode
      + per-class NMS, `nms . nms == nms` property per 09-testing.md).
      **Slice 3 done (Aug 12 2026)**: `Hnvr.Cv.Decode` — `decode`
      ([1,84,anchors] → `V.Vector Detection`, conf threshold + class
      whitelist, defaults 0.35 / [0,1,2,3,5,7] per design), `nms`
      (per-class, desc-score greedy, list-based — `V.groupBy` doesn't
      exist in boxed Data.Vector; suppression-stable so idempotence
      holds), `iou`, `unletterboxBox` (Letterbox → source pixels).
      15 new tests: golden [1,84,3] decode, IoU arithmetic, 5 NMS
      behavior pins, unletterbox golden, + 3 QuickCheck props
      (idempotence, subset, filter-respect). hnvr-cv suite: 27 total.
      **Slice 5 done (Aug 12 2026)**: `Hnvr.Cv.Analyzer` — per-camera
      pipeline kernel (`withAnalyzer` wraps `withSession`; `analyzeFrame`:
      preprocess → infer → decode+NMS → unletterbox → SORT update →
      confirmed tracks). `parseExecProviders` (strict Either;
      `trt` alias; loud on typos) + `execProvidersFromEnv` (defaults
      [CPU]). OnnxRuntime extended with shape introspection
      (`sessionInputShape`/`sessionOutputShape` via
      SessionGet{Input,Output}TypeInfo idx 33/34 + Cast 55 +
      ReleaseTypeInfo 98 — pitfall #93). Gated pipeline test on
      `HNVR_TEST_MODEL` (also doubles as a model-shape probe,
      pitfall #94/#95). hnvr-cv suite: 53 total.
      **Slice 6 done (Aug 12 2026)**: analysis frame path wired
      end-to-end. `Hnvr.Capture.Ffmpeg.analysisArgs` (sub-stream
      decode OR relay+scale=640:360 fallback per 03 §2b),
      `Hnvr.Capture.FrameSource` (ffmpeg → RGB24 slice → bounded
      TBQueue, drop-oldest — CV never backpressures the pipe;
      backoff-supervised `frameSourceLoop`), `Hnvr.Cv.AnalyzerRunner`
      (queue → analyzeFrame → sink, session reused across restarts).
      `CameraSnapshot` extended (+csRtspSubUrl/csUseSubstream/
      csSubWidth/csSubHeight/csAnalysisFps; projectCamera +
      SnapshotResponder SQL updated). `CaptureSupervisor` spawns the
      analysis pair per camera when `HNVR_MODEL_PATH` set and
      `HNVR_ANALYSIS_ENABLED != 0`; `latestAnalysis` exposes
      (frame, confirmed tracks) TVar for the /debug view. hnvr-web
      now deps on hnvr-cv — `nix build .#hnvr-web` green. devenv
      env: HNVR_ONNXRUNTIME_LIB (pinned store path), HNVR_MODEL_PATH
      (yolov8n-320), HNVR_EXEC_PROVIDERS="tensorrt,cuda,cpu".
      Pitfall #98: pinned-vs-channel onnxruntime (1.27.1 vs 1.24.4),
      indices verified identical, ortApiVersion now 27. Tests: 34
      capture + 97 core + 53 cv + 16 nats + 5 storage = 205 cabal.
      **Slice 8 done (Aug 13 2026)**: EKG metrics. `Hnvr.Core.Metrics`
      (Metrics record of IO actions + pure `renderPrometheus` —
      hnvr-capture/hnvr-cv stay ekg-free), `Hnvr.Web.Metrics`
      (ekg-core Store, per-camera/per-EP lazy metric caches, warp
      /metrics on HNVR_METRICS_PORT default 9100, nvidia-smi GPU
      gauge poller). `CaptureConfig.capMetrics` is the seam;
      `FrameSource.writeDropOldest` now returns STM Bool for the drop
      counter; `AnalyzerRunner` times `analyzeFrame` and records under
      the session's ACTUAL EP (`sessionActiveEp`). Metrics live:
      `hnvr_frames_decoded_total{camera}`, `hnvr_frames_dropped_total{camera}`,
      `hnvr_inference_seconds_{count,sum}{ep}`,
      `hnvr_substream_fallback_total{camera}`,
      `hnvr_gpu_memory_used_bytes`. Verified live on all 3 cams (ep
      label correctly reports cpu pre-CUDA-build). Pitfalls #101
      (ekg-core min/max broken under -N — renderer emits count/sum
      only) + #102 (metrics = own warp, not IHP middleware). hnvr-core
      103 tests, capture 35 — total 217 cabal.
      **Slice 9 done (Aug 13 2026)**: CUDA. flake.nix gains
      `cudaPkgs` (separate nixpkgs import: `cudaSupport=true`,
      `cudaCapabilities=["8.9"]`, `allowUnfree`) +
      `packages.onnxruntime-cuda` (1.27.1, `pythonSupport=false`;
      derivation verified: USE_CUDA=TRUE, CMAKE_CUDA_ARCHITECTURES=89).
      devenv HNVR_ONNXRUNTIME_LIB flipped to the CUDA build;
      enterShell prepends /run/opengl-driver/lib to LD_LIBRARY_PATH
      (libcuda.so.1 discovery). Build: `nix build .#onnxruntime-cuda`
      (~30 min on Sergey's box; pulls opencv into the dep chain).
      **Verified live**: leader on the CUDA lib reports
      `hnvr_inference_seconds{ep="cuda"}` — 3170 inferences in 3 min,
      ~9.2 ms/frame full pipeline (vs ~13.2 ms CPU), no crashes.
      Note: pinned nixpkgs builds no TensorRT EP — `tensorrt` in
      HNVR_EXEC_PROVIDERS falls through to cuda; TRT engine CI job
      still open.
      **Slice 10 done (Aug 13 2026)**: NixOS module CV wiring +
      hnvr-1 EP decision. `nix/module.nix` gains
      `onnxruntimePackage` (default CPU `pkgs.onnxruntime`; hnvr-2
      overrides with `packages.onnxruntime-cuda`), `execProviders`
      (default "cpu"; hnvr-2 "tensorrt,cuda,cpu"), `modelPath`
      (null = analysis off), `metricsPort` (9100), plus
      LD_LIBRARY_PATH=/run/opengl-driver/lib. **hnvr-1 runs CPU EP in
      v1** (Sergey's call): nvcc 12.9 still emits sm_61 SASS, but
      cuDNN ≥ 9.12 dropped Maxwell/Pascal entirely (eval-level
      `badPlatforms` in nixpkgs) and ORT 1.27's CUDA EP hard-links
      cuDNN (no USE_CUDNN switch anymore; only CUDA_MINIMAL, which
      guts kernel coverage). CPU ~80 ms/frame ≈ 12.5 fps capacity —
      fine for 5 fps sub-streams, drop-oldest absorbs 15 fps cams.
      Revisit if hnvr-1 gets a Turing+ card. Also fixed a latent
      smoke-test breakage: module referenced
      `config.services.hnvr.secrets.enable` without the hnvr-secrets
      module imported (broken since M4) — now `… or false`.
      `checks.hnvr-leader-smoke` green again with the new env.
      **Slice 11 done (Aug 13 2026)**: TensorRT EP. flake's
      `onnxruntime-cuda` now builds ORT's TRT EP:
      `onnxruntime_USE_TENSORRT=ON` + `TENSORRT_HOME` =
      symlinkJoin of tensorrt 10.14.1.48 outputs (incl. `static` —
      but see pitfall #104: builtin-parser flag sidesteps
      onnx-tensorrt entirely) + `permittedInsecurePackages` for the
      TRT redist (computed dynamically, minioVersion pattern).
      FFI: `UpdateTensorRTProviderOptions` (vtable idx 172,
      re-derived from the pinned 1.27.1 -dev header) sets
      `trt_engine_cache_enable/path` + `trt_timing_cache_enable`
      from `HNVR_TRT_CACHE_DIR` (default: system temp dir; devenv
      wires DEVENV_STATE/trt-cache; module wires ${dataDir}/trt-cache).
      **Engine cache supersedes the roadmap's trtexec CI job** —
      GPU-less CI runners can't build sm_89 engines; ORT builds the
      engine once per host (~60 s first analyzer start) and cache-hits
      afterwards (0.6 s). Verified: gated test HNVR_TEST_TRT=1 (60.75 s
      cold / 0.61 s warm), live leader reports
      `hnvr_inference_seconds{ep="tensorrt"}` ~7.8 ms/frame pipeline
      avg (vs 9.2 CUDA / 13.2 CPU). Frame drops during the cold-start
      engine build are expected (analyzer blocks in CreateSession).
      cv suite: 59 tests.
      **Slice 12 done (Aug 13 2026)**: resolution bump + leak fix.
      `withAnalyzer` derives the letterbox target from the session's
      input shape (yolov8s-640 drop-in); `HNVR_ANALYSIS_SCALE` (WxH)
      drives the fallback-path scale (1280x720 for backyard — its
      sub-stream stopped answering ffprobe, still on relay fallback);
      low_ent sub dims filled (704×576, direct sub now). Debug view:
      camera Show page + dashboard cards link `/DebugCamera?cameraId=…`;
      legend renders COCO names (`cocoClassName`) + percent scores.
      **Leader OOM fixed** (pitfall #105): lazy `Sort.update` chain
      leaked ~one frame per frame; now forced per frame. Verified:
      LeakProbe fulllazy 5000 frames clean, leader flat ~2.6 GB RSS
      over 15 min at yolov8s-640/TRT/3 cams (was ~80 MB/s growth).
      cv suite: 61 tests. New dev tool: `hnvr-cv:hnvr-leak-probe`.
      **Phase 3 close-out done (Aug 14 2026)**: bake + accuracy
      tooling + per-camera model plumbing + coverage pass. New exes
      (`hnvr-cv/app`): `hnvr-cv-soak` (live stream → production
      frameSourceLoop+runAnalyzer path; 60 s tick: decoded/dropped/
      analyzed/per-EP avg inference ms/VmRSS; `--minutes` bound) and
      `hnvr-cv-compare` (N frames → both models; per-frame detections
      at `--conf` 0.10 + by-class summary + person-verdict
      disagreements + `--png-dir` annotated PNGs). `cameras.model_name`
      landed (Schema.sql + regen — 7 stale audit_log Generated modules
      surfaced, hand-added to hnvr-web.cabal per pitfall #51; New/Edit
      forms gained an Analysis-model select). CaptureSupervisor
      `resolveModelPath`: bare name → `HNVR_MODEL_DIR` (default:
      dirname of `HNVR_MODEL_PATH`) `<name>.onnx`; missing file →
      warn + env fallback. nix module gained `modelDir`. Pitfall #107
      async-exception audit: FrameSource/Worker/SpoolDrainer
      SomeException catches now rethrow SomeAsyncException (was:
      cancel on a frame source respawned ffmpeg forever). First live
      compare (backyard relay 1280x720, CPU EP): s-640 = 59 dets
      (car max 0.87, truck detected) vs n-320 = 33 (car max 0.71,
      truck misread as car) → backyard is an s-640 camera;
      floor_2_5 frames had no objects (no signal). **Resolved**: the
      "0 confirmed tracks" anomaly was a compare-tool bug (tracker
      state never threaded between frames — every frame birthed fresh
      tracks); SORT itself is fine. Fixed run (backyard, 8 frames):
      n-320 = 6 confirmed tracks, s-640 = 10, and s-640 caught a
      person on frames 4–6 that n-320 missed entirely. Sergey set the
      per-camera calls in the DB: backyard + low_ent → yolov8s-640,
      floor_2_5 → yolov8n-320; verified live via snapshot →
      resolveModelPath (node log prints the per-camera model). Coverage: +56 tests
      (272 total): CameraSnapshot/Event/Frame, SpoolDrainer,
      Worker.transition, gated AnalyzerRunner loop, storage pure lane.
      Remaining Phase 3: the longer soak run itself + final
      per-camera model call (needs a person in frame on floor_2_5 /
      low_ent).
      **Slice 7 done (Aug 12 2026)**: /debug view + the great SIGSEGV
      hunt. `Hnvr.Cv.DebugRender` (pure: palette box overlay +
      JuicyPixels PNG — MJPEG→PNG-multipart deviation documented;
      no JPEG encoder in JuicyPixels), `Hnvr.Web.DebugStream` WAI
      middleware (`/debug-stream/<uuid>` multipart stream, STM
      blocking on the analysis TVar), `Web.Controller.Debug` +
      `View.Debug.Show` (auth-gated HTML shell + track legend with
      matching CSS colors), `Hnvr.Web.SupervisorRegistry`
      (process-wide IORef; supervisor is created in an IHP
      initializer so `option` can't carry it). **Root-caused the
      leader crash: uninitialized ORT output slot** (pitfall #99) —
      alloca garbage read as non-null `OrtValue*` → ORT copy-ctor on
      garbage pointer. Also landed: input-vector liveness wrapping
      all of create+Run, SetIntraOpNumThreads=4 + DisableMemPattern +
      DisableCpuMemArena (multi-session hygiene), HNVR_ORT_DEBUG=1
      stderr tracing, HNVR_STRESS=1 gated stress test (2000-frame
      analyzeFrame loop with GC churn). Verified live: 3 cameras ×
      analysis, 4+ min stable (all prior crash points were 30–130s),
      debug streams for floor_2_5 (direct sub) + low_ent (relay
      fallback) both serve multipart PNG at 5fps. cv suite: 58.
      Remaining Phase 3: EKG metrics, TRT engine CI job, longer bake.
      Next slice: analysis ffmpeg (sub-stream → Frame TChan producer)
      + worker loop wiring into hnvr-capture/NodeMain.
      Next slice: Tracker.Sort (Kalman 6×4 + Hungarian,
      `hungarian-algorithm` pkg, determinism property).
      **Slice 4 done (Aug 12 2026)**: `Hnvr.Cv.Tracker.{Kalman,Hungarian,
      Sort}`. Design-doc corrections: **`hungarian-algorithm-1.0.0` does
      NOT exist on Hackage** — implemented Kuhn–Munkres in-tree
      (`Hungarian.hs`, e-maxx port over Data.Vector+ST, rectangular via
      dummy-cost square padding, deterministic tie-breaks); and massiv
      has no 4×4 inverse, so Kalman carries its own tiny dense-matrix
      ops (Gauss-Jordan partial pivot). Sort: predict → assign (1−IoU
      cost, gate 0.3) → update/birth/prune; defaults maxAge=30,
      minHits=3 per design. 17 new tests (6 Hungarian golden + 3 Kalman
      + 6 Sort + determinism & ID-stability props). hnvr-cv suite: 44
      total. Watch out: QuickCheck default size × O(n³) Hungarian =
      minutes — `resize 12` in the determinism prop.
- [x] Phase 4 — Events (line crossing + zone)  ← v1.0 release candidate.
      **Backend pipeline done (Aug 13 2026)**: `Hnvr.Cv.Rules`
      (pure engine: line-cross direction sign, ray-cast point-in-poly,
      per-(rule,track) cooldown/zone state, `projectRule` wire→typed,
      `evalTracks` with dead-track pruning — 23 unit+property tests).
      Migration 0003 (rules + events tables + enums; complex partial
      indexes live ONLY in the migration — IHP's schema-compiler can't
      parse `NOT IN`/`IS NOT NULL` index predicates). IHP codegen
      regenerated (new Generated.{Rule,Event}* modules, hand-added to
      hnvr-web.cabal per pitfall #51). `Track` gained `tPrevBox`
      (movement segment for line-cross). Wire: `RuleSnapshot` +
      `CvEvent` in hnvr-core; SnapshotResponder joins rules (SQL needs
      `kind::text` — postgresql-simple won't decode PG enums to Text);
      `CaptureSupervisor.analysisSink` evals rules per frame and
      publishes `CvEvent` on hnvr.events; EventWriter persists
      (needs `?::uuid` + `?::jsonb` casts for rule_id/bbox).
      AssignPayload path does NOT carry rules (csRules=[]) — rules
      propagate via snapshot only; Phase 4 follow-up. Verified live:
      full-frame test zone on backyard → 18 zone_enter events persisted,
      zero insert errors. **Thumbnails + /Events UI done (Aug 14
      2026)**: sink draws the offending track's bbox on the frame
      (renderDebugPng) and uploads to S3 `<slug>/events/<ts>.png`
      (failure → NULL thumbnail_key, event still persists); CvEvent +
      EventWriter carry thumbnail_key. `/Events` (nav link added):
      filter by camera/kind/window, 20/page (LIMIT+1 next-page probe),
      presigned 1h thumbnail GETs, deep-links into the archive player
      (`/PlayerArchive?cameraId&from&to&t`, ±30s window). Pitfalls
      hit: IHP hasql sqlQuery has no FromRow for 10-tuples →
      fetchEventRows uses a one-shot postgresql-simple connection
      (SnapshotResponder pattern); float4 `confidence` needs an
      explicit `Maybe Float` annotation (GHC defaults to Integer →
      IHP's "Database looks outdated" page); NoFieldSelectors again
      (record-dot in the view).
      **Rules CRUD + live propagation done (Aug 14 2026)**:
      `/debug-frame/<uuid>` one-shot PNG (DebugStream middleware) is the
      drawing canvas background; `Web.Controller.Rules` CRUD
      (PurgeRuleAction per pitfall #82 — no Delete* prefix); New/Edit
      share `ruleForm` (canvas click-to-draw line/polygon, normalized
      coords into a hidden JSON input, direction select for lines,
      class checkboxes → hidden csv input; inline script via
      body-level `preEscapedTextValue` per pitfall #63; the
      shared-helper signature needed `(?context::Request,
      ?request::Request) =>` + RankNTypes per pitfall #36).
      `Hnvr.Web.BusRegistry` (same IORef pattern as
      SupervisorRegistry) lets controllers publish: every rule
      mutation republishes the camera's assign payload with fresh
      rules (`projectCameraWithRules` — closes the AssignPayload
      csRules=[] gap), owning host restarts the analysis pair via
      ConfigWatcher. Camera Show page gained a "New rule" button; nav
      has /Rules + /Events. Verified: create/edit/purge round-trip via
      curl, EditRule prefills geometry, worker restarts on rule change.
      **Remaining Phase 4**: live event feed on /live, audit log.
      **Live feed + audit log done (Aug 14 2026)**: /live page has an
      Events panel polled every 5 s from `EventsFeedLiveAction` (HTML
      fragment, last 10 per camera — IHP autoRefresh needs ihp.js,
      which our layout doesn't load, so a fetch poller). Migration
      0004 `audit_log` + `Hnvr.Web.Audit.audit` (never-throws helper)
      wired into rule create/update/delete + camera
      create/update/delete/assign; user id via `currentUserOrNothing`
      (helper signature needs `(?request :: Request) =>`). Phase 4
      feature-complete per roadmap. Playwright `rules.spec.ts` (4
      specs: canvas line create→edit→purge, zone polygon, /Events
      table, live feed poller) — full suite 23 passed + 1 pre-existing
      skip. Gotcha: pre-commit ormolu runs in the nix sandbox and does
      NOT modify the working tree — run `ormolu -i` yourself before
      committing.
- [ ] Phase 5 — PTZ manual + presets          ← v1.0 release
- [ ] Phase 6 — Operational hardening
- [ ] Phase 7 — Auto-track milestone           ← v1.1
- [ ] Phase 8 — Polish

Phase 1 kickoff notes:
- **DONE (Aug 9 2026)**: Camera sub-streams verified via ffprobe. All three
  cameras have a usable sub-stream; see "Sergey's cameras" fixture table
  above for Sergey's canonical URL form. Sub-stream fps is 5 on 196 + 198
  (may need main-stream-with-scale fallback for CV in Phase 3).
- The leader's NATS connection is best-effort (won't crash IHP on
  failure); when wiring EventWriter in Phase 1, store the Bus in an
  MVar so it's accessible to publish sites.
- Replace local Postgres in leader VM with the SaaS one when ready.
- Decide JetStream path (vendoring vs `nats` CLI subprocess).
- NATS HTTP monitor (`/connz`) on QEMU hostfwd returns TCP RST when
  probing from outside the VM (auth handshake quirk); binary-level
  connectivity test passes. Investigate before relying on monitor in
  multi-host tests.

See `design_docs/08-roadmap.md` for the full plan with demos and decision points.

## Next session quick-start

1. `cd /home/pion/work/dev/hnvr`
2. Read this file.
3. Skim `design_docs/00-overview.md` for the decisions table.
4. Check `git log --oneline` for what's new since last session.
5. `nix develop --no-pure-eval` (or direnv) to enter dev shell.
6. **Phase 1 + Phase 2 + test infrastructure (S1–S5) all done**.
   Next priorities (pick one):
   - **Phase 3 CV pipeline** — implement `Hnvr.Cv.OnnxRuntime` (FFI
     binding), `Preprocess`, `Decode`, `Tracker.Sort`. Then S6 test
     slice lands alongside per design_docs/10-test-plan.md.
   - **Two-node NixOS failover test** — reconfigure both VMs to peer
     with a shared NATS cluster so `hnvr.health.>` crosses VM
     boundaries (current worker VM uses its own localhost NATS per
     Phase 0 demo wiring). Then write `nixosTests.hnvr-failover`.
   - **Phase 6 operational hardening** — sops-nix secrets wiring,
     mediamtx auth, retention sweep.
