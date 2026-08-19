# HNVR — Roadmap

Phased delivery. Each phase ends with a demonstrable, deployable system. Two hosts throughout: hnvr-1 (GTX 1070, worker), hnvr-2 (RTX 4090, leader).

## Phase 0 — Bootstrap (week 1)

Goal: two NixOS VMs build and run the binaries, NATS connected, IHP returns `/healthz`.

**Landed.** Notes: IHP is pinned to release v1.6.0 (not a master commit);
JetStream helpers never materialized (nats-queue is core-NATS only, JetStream
deferred); amazonka was dropped for vendored minio-hs.

- [x] `flake.nix` with `haskell-flake` + IHP pinned to release v1.6.0
- [x] GHC 9.12 jailbreak overlay (`cabal-test-quickcheck`, `postgresql-simple-migration`; amazonka dropped — storage is vendored minio-hs)
- [x] `ihp new hnvr-web` skeleton
- [x] `nix/module.nix` minimal (one binary, no GPU, no NATS yet)
- [x] `nix/nats-server.nix` (single-node NATS; JetStream server-side enabled but unused by the app)
- [x] `hnvr-nats` sublib: connection pool, basic pub/sub, JSON codecs (core NATS only)
- [x] `devShell.nix` with cabal, ghcid, ormolu, hlint, nats-server, mediamtx
- [x] `pre-commit-hooks.nix` config
- [x] CI: `nix flake check` + `cabal build all` on push (matrix GHC 9.10 sanity + 9.12 target)
- [x] `healthz` action returning 200

**Demo**: two NixOS VMs (`nix run .#nixosConfigurations.hnvr-1-vm` / `hnvr-2-vm`) come up; `curl hnvr-2:8000/healthz` returns 200; NATS monitoring shows both connected.

## Phase 1 — Recording MVP (weeks 2–3)

Goal: camera in → fMP4 fragments in SeaweedFS → row in `segments` table → archive playback in browser.

**Landed.** Notes: storage lib is vendored minio-hs (path-style) — amazonka
never compiled under GHC 9.12 and was dropped; `rtsp_sub_template` (and
`rtsp_template`/`port`) were dropped in migration 0010 — URLs are stored
verbatim. Retention moved `retention_days` → `retention_hours` (0007).

- [x] `hnvr-core`: `CameraId`, `Box`, `Sha256`, `HostId`, `UTCTime` helpers, structured logging
- [x] `hnvr-storage`: SeaweedFS client wrapper (vendored minio-hs with path-style), segment publish
- [x] `hnvr-capture`:
  - [x] fMP4 fragmenter (~80 LOC parser)
  - [x] `CaptureWorker` state machine
  - [x] Recording ffmpeg invocation (main stream, `-c:v copy`)
  - [x] SeaweedFS put + `SegmentWritten` publish on `hnvr.events`
  - [x] Backoff / supervision
- [x] `hnvr-leader` EventWriter: consume `hnvr.events`, filter `kind='segment_written'`, insert into `segments`
- [x] IHP `cameras` CRUD (admin only); `assigned_host` auto-assigned by `AssignmentCoordinator`
  - [x] Sub-stream fields: `rtsp_sub_url`, `use_substream_for_analysis`, etc. (`rtsp_sub_template` dropped, 0010)
  - [x] "Probe sub-stream" button in UI (runs `ffprobe` server-side, fills dims + codec)
- [x] IHP `archive` action: m3u8 generation, presigned URLs
- [x] `<video>` + hls.js on archive page
- [x] Camera password encryption (`hnvr-core/Crypto.hs`)
- [x] sops-nix integration for `hnvr-data-key` + `hnvr-config` (whole hnvr.yaml incl. S3 creds) + PG URL

**Demo**: Sergey adds one camera via UI; main stream + sub-stream both probe successfully; sees a 1-hour playback window with seek.

**Out of scope for Phase 1**: live view, CV inference, audio, retention sweep, exports, multi-host failover.

## Phase 2 — Live View + Multi-Host (week 4)

Goal: low-latency live view in browser; second host carries half the cameras.

**Landed.** Notes: MediaMTX config is pushed via the /v3 REST API (no
mediamtx.yml regen, no SIGHUP); live view shipped as `/ShowLive?cameraId=…`;
nginx was never deployed — the WHEP proxy is WAI middleware inside the app.

- [x] Add `mediamtx` flake input + `systemd.services.mediamtx` (leader only)
- [x] `MediaMTXConfigSyncer`:
  - [x] Postgres LISTEN on `cameras_events` (pg-simple)
  - [x] Push path add/patch/delete via the MediaMTX /v3 REST API
- [x] `/ShowLive?cameraId=…` view + WHEP client JS
- [x] `/whep/<slug>` reverse proxy (WAI middleware; no nginx)
- [x] **Multi-host:**
  - [x] `AssignmentCoordinator` on leader
  - [x] `hnvr.commands.assign.<cam>` + `hnvr.commands.control.<host>.<cam>.<action>`
  - [x] `ConfigWatcher` per host subscribes `hnvr.config.>`
  - [x] Health publication `hnvr.health.<host>` every 5 s
- [x] Dashboard with camera grid + per-host panel
- [x] Camera assignment UI (`POST /cameras/:id/assign`)

**Demo**: 6 cameras split 3/3 across hnvr-1 + hnvr-2; kill hnvr-1; cameras reassigned to hnvr-2 within 15 s; live view keeps working.

## Phase 3 — CV: detection + tracking (weeks 5–6)

Goal: YOLOv8n detections with persistent track IDs, visible in a debug overlay, on **both** hosts with appropriate EPs.

- [x] `hnvr-cv/OnnxRuntime.hs`: minimal internal C API binding (~150 LOC) — no Hackage dep
- [x] `Hnvr.Cv.Preprocess`: `massiv` letterbox (any input → 320×320) + normalize
- [x] `Hnvr.Cv.Decode`: YOLOv8 anchor decode + NMS
- [x] `Hnvr.Cv.Tracker.Sort`: Kalman + Hungarian (Kuhn–Munkres in-tree — `hungarian-algorithm` doesn't exist on Hackage)
- [x] `AnalyzerWorker` glue (consumes sub-stream Frame TChan from CaptureWorker)
- [x] EP selection from `HNVR_EXEC_PROVIDERS`:
  - [x] hnvr-1: CPU EP — criterion revised: cuDNN ≥ 9.12 dropped Pascal, so the CUDA EP is unavailable; hnvr-1 runs CPU EP only
  - [x] hnvr-2: TensorRT EP — via on-host ORT engine cache (`HNVR_TRT_CACHE_DIR`); **the trtexec CI job below is superseded** (GPU-less CI runners can't build sm_89 engines)
- [x] ~~CI job to pre-build TensorRT engines via `trtexec`~~ (superseded — see above)
- [x] Debug view `/DebugCamera?cameraId=…` showing live frame with bbox overlay + track IDs (session-gated multipart stream at `/StreamDebugCamera?cameraId=…`; the anonymous `/debug-frame/<uuid>` single-frame endpoint stays for the dashboard wall)
- [x] EKG metrics: `hnvr_frames_decoded_total`, `hnvr_frames_dropped_total`, `hnvr_inference_seconds_{count,sum}{ep}`, `hnvr_substream_fallback_total`, `hnvr_gpu_memory_used_bytes` (Prometheus text on `HNVR_METRICS_PORT`, default 9100)
- [x] Resolution bump: `withAnalyzer` follows the session's input shape (yolov8n-320 ↔ yolov8s-640 drop-in); `HNVR_ANALYSIS_SCALE` for the fallback path
- [x] Lazy-SORT heap leak fix (`.opencode/MEMORIES.md` pitfall #105)

**Demo**: open `/DebugCamera?cameraId=…`, see bounding boxes following people; EKG shows EP labels per camera. Disable sub-stream on the camera → analyzer auto-falls-back to main-stream-with-scale; `hnvr_substream_fallback_total` increments; recording unaffected.

**No events yet** — just proves the pipeline end-to-end. Remaining: the longer soak itself (tooling: `hnvr-cv-soak`, Aug 14 2026) + final per-camera YOLOv8n-320 vs YOLOv8s-640 call (tooling: `hnvr-cv-compare`; per-camera `cameras.model_name` plumbing landed Aug 14 2026; first data point: backyard → s-640).

## Phase 4 — Events: line crossing + zone intrusion (weeks 7–8)

Goal: emit and persist events; UI for rules and events.

**Landed.** Additions beyond the bullets: `zone_motion` rule kind with
`min_displacement` (migration 0005); **event video clips** (v0.4.0.0) —
rules with `clip_preroll_sec`/`clip_postroll_sec`/`clip_retention_hours` get
node-assembled clips under `<slug>/clips/…`, `event_clips` +
`event_clip_events` tables (0007), playback at `/PlayerEventClip` +
`/PlaylistEventClip`, admin purge with tombstones. Events carry the full
CvEvent JSON in `payload`; deep-links go to `/PlayerArchive?…&t=<ts>`.

- [x] `rules` table + CRUD UI (line drawing on a still frame)
- [x] `Hnvr.Cv.Rules` engine (segment intersect, point-in-polygon)
- [x] Per-rule cooldown state in analyzer
- [x] `AnalyzerWorker` publishes events on `hnvr.events`
- [x] Leader's `EventWriter` consumes CV events (in addition to `segment_written`) → Postgres
- [x] `events` table + indexes
- [x] `/events` view with filters
- [x] Event thumbnails (JuicyPixels bbox draw + SeaweedFS put)
- [x] Click event → deep-link to `/PlayerArchive?…&t=<ts>`
- [x] Live event feed on the live view
- [x] Audit log
- [x] Event video clips (v0.4.0.0 — see note above)

**Demo**: draw a line across a doorway; person walks through; event appears in UI and live feed; click plays the second of the crossing.

## Phase 5 — PTZ manual control + presets (weeks 9–10)

Goal: full manual PTZ from the web UI; preset management; idle return-to-home.

**Landed Aug 16 2026 (v0.6.0.0)**. Deviations from the original bullet list:
no `ptz_onvif_url`/`ptz_username`/`ptz_password_enc` columns (PTZ XAddr is
discovered at controller start via GetCapabilities; ONVIF reuses the camera
credentials); the audit feed is node→leader on `hnvr.ptz.audit` (nodes have
no DB access) so rows record execution with ok/error, not publish intent.
**Fleet caveat: none of Sergey's three cameras have working PTZ hardware** —
196 accepts all ops as no-ops (position register frozen, image diff shows no
movement), 197 reports nil PTZStatus, 198 (Majestic) advertises no PTZ
service. Verified protocol-level end-to-end against 196.

- [x] `hnvr-ptz` sublib:
  - [x] ONVIF SOAP client PTZ subset (extends the Phase-4 config-sync client:
    `tptz` ns + SOAPAction mapping; discoverPtzXAddr, GetPresets, GotoPreset,
    SetPreset, RemovePreset, ContinuousMove, Stop, AbsoluteMove, GetStatus,
    GetProfiles tokens)
  - [x] WS-Security UsernameToken auth (SHA-1 digest) — landed in Phase 4
  - [x] Driver as resolved-endpoint record (`Hnvr.Ptz.Onvif.OnvifPtz`) —
    the design's typeclass dropped (no error channel); ops return
    `Either OnvifError`
- [x] `PtzController` per PTZ-enabled camera (command loop + 1 s idle ticker)
- [x] PTZ state machine (Idle, ManualMove, GoingToPreset, ReturningHome)
- [x] NATS subjects: `hnvr.commands.ptz.<cam>` (+request/reply for
  set_preset/get_presets), `hnvr.ptz.status.<cam>`, `hnvr.ptz.audit`
- [x] `ptz_presets` + `ptz_audit_log` tables (migration 0011; audit log
  gained ok/error columns)
- [x] Camera config: `ptz_enabled`, `ptz_profile_token`, `ptz_home_preset_id`,
  `ptz_idle_timeout_s`, `ptz_viewer_control`
- [x] IHP:
  - [x] `POST /PtzCamera?ptzCameraId=…` (publishes NATS command; JSON)
  - [x] `/PtzPresets?ptzCameraId=…` CRUD UI (+ goto/home; format=json for fetch)
  - [x] "Probe PTZ" button on camera edit (discovers PTZ service + fills
    profile token; warns on nil status = no hardware)
- [x] Live view PTZ panel (8-way hold-to-move pad + zoom + preset dropdown)
  - [x] `static/ptz.js` (~110 LOC vanilla JS)
  - [x] PTZ status indicator (1 Hz poll of /PtzStatusCamera, fed by the
    hnvr.ptz.status.> cache)
- [x] Idle timeout → return to home preset (absolute origin when no home)
- [x] Audit log of every PTZ command (ptz_audit_log, written leader-side
  from the node's audit feed)
- [x] EKG metrics: `hnvr_ptz_commands_total{cam,command,source}`,
  `hnvr_ptz_command_seconds`

**Demo**: open live view of a PTZ camera, drag joystick to pan, click preset to jump to saved position, idle for 30 s → camera returns to home preset. Disable PTZ via UI toggle → control panel disappears.

This is the **v1.0 release**. Tag it. Ship it.

## Phase 6 — Operational hardening (weeks 11–12)

- [ ] `RetentionSweeper` hourly cron (leader)  *(shipped early — hours-based, also sweeps event_clips + stale tombstones)*
- [ ] `recording_gaps` detection on segment loss
- [ ] ~~Export jobs (`POST /archive/<slug>/clip`)~~ — never shipped; event clips (v0.4.0.0) replaced the design
- [ ] Prometheus dashboard JSON for Grafana (capture + CV + NATS + GPU + PTZ)
- [ ] Healthcheck + alerting hooks (webhook out on `FailedPermanent`)
- [ ] Logrotate integration
- [ ] Hardened systemd unit (full sandbox matrix)
- [ ] NATS JetStream stream config (deferred — nats-queue has no JetStream; app is core-NATS only)
- [ ] Documentation: `README.md`, operations runbook, schema diagram

## Phase 7 — v1.1: Auto-track milestone (weeks 13–15)

Goal: PTZ cameras follow the largest matching object automatically.

- [ ] `Hnvr.Cv.AutoTrack` consumer module
- [ ] Target selector (largest bbox, sticky track_id)
- [ ] PID controllers (pan, tilt, zoom — independent, per-camera tunable)
- [ ] Dead band + rate limit + windup guard
- [ ] `AutoTracking` state in PtzController state machine
- [ ] Manual preemption (any UI PTZ command clears AutoTracking)
- [ ] Lost-target timeout → Stop; extended-loss → ReturningHome
- [ ] Camera config: autotrack_enabled, autotrack_classes, autotrack_desired_area, autotrack_*_pid JSONB, timeouts
- [ ] Admin tuning panel with live preview
- [ ] EKG: `hnvr_autotrack_target_locked{cam}`, `hnvr_autotrack_pid_output{cam,axis}`
- [ ] Field tuning: 1–2 weeks per camera model with real test scenes

**Demo**: walk across the camera's field of view; camera pans to follow; stop and stand still; camera holds; walk out of frame; after timeout, camera returns to home preset.

## Phase 8 — v1.2 polish (post-launch)

- [ ] Standby web node on hnvr-1 (leader election via JetStream KV — blocked on JetStream, deferred)
- [ ] NATS cluster of 2 → 3 nodes (HNVR-bus HA)
- [ ] Multi-camera synchronized player
- [ ] HLS low-latency (LL-HLS) fallback when WebRTC blocked
- [ ] Per-user preferences (default camera, retention overrides)
- [ ] Webhook delivery system (Telegram / email / ntfy)
- [ ] GPU auto-detection at startup (drop manual `HNVR_EXEC_PROVIDERS`)
- [ ] Model hot-reload (no service restart)
- [ ] `pg_partman` partitioning for `events`/`segments` (monthly)
- [ ] Mobile-responsive UI pass
- [ ] Internationalization (English + Russian, IHP's i18n support)
- [ ] **Scheduled PTZ tours**: named sequences of presets with dwell times; cron-like schedule
- [ ] **Operator-pinned auto-track target**: click on a track in live view to lock onto it

## Stretch / nice-to-haves

- Face recognition plugin (insightface ONNX)
- License plate reader plugin
- Anomaly detection (custom model)
- Audio analytics (glass break, baby cry)
- Mobile app (React Native or solid PWA)
- iOS HLS HEVC support (requires `hvc1` re-boxing)
- **ONVIF Device Service Discovery** — auto-discover cameras on the LAN; probe main + sub stream URLs and supported resolutions; one-click add
- Auto-fisheye dewarp for ceiling-mounted cameras
- Live histogram / motion heatmap overlay
- Long-term storage tiering (SeaweedFS hot → cold bucket tier)

## Decision points to revisit

| Question | Trigger |
|----------|---------|
| Is the internal ONNX binding (~150 LOC) easier than patching `hs-onnxruntime-capi`? | Phase 3 kickoff |
| Does our fMP4 actually play in hls.js without re-mux? | Phase 1 end — if not, add `-bsf:v hevc_mp4toannexb` or MP4Box side-step |
| Do Sergey's cameras actually expose a usable sub-stream? (`stream=SubStream` / `stream=1`) | Phase 1 kickoff — probe with ffprobe; if not, `use_substream_for_analysis=false` and main-stream-with-scale path is the default |
| Do Sergey's cameras actually expose ONVIF PTZ? (enable in camera web UI; check `GetCapabilities`) | Phase 5 kickoff — if not, defer PTZ or build vendor-CGI backend for the specific brand |
| Does MediaMTX v1.20 WHEP work cleanly with Chrome 130+? | Phase 2 kickoff — if not, fall back to WHIP+peerjs or HLS |
| Is YOLOv8n-320 accurate enough on Sergey's cameras? | Phase 3 end — bump to YOLOv8s-640 on RTX 4090 host if precision is bad |
| Is TensorRT engine rebuild stable across TensorRT versions? | Phase 6 — pin TensorRT version per nixpkgs release |
| Does NATS handle our event rate (25 msgs/sec) on core subjects? | Phase 4 — if not, batch events before publish (durability via JetStream deferred) |
| Can we drop `segment_written` events to halve NATS traffic? | Phase 6 — workers write directly to PG if NATS chokes |
| Are the default PID constants (`p:0.4, i:0.05, d:0.1`) a workable starting point for Sergey's camera models? | Phase 7 kickoff — auto-track tuning may need per-model profiles |

## Definition of Done (v1.0)

1. ✅ 24/7 recording of ≥ 6 cameras split across both hosts with < 1 s gap on the median day.
2. ✅ Live view opens in < 2 s in Chrome, sub-second glass-to-glass latency.
3. ✅ At least one line-crossing rule firing events with thumbnails, deep-linked to playback.
4. ✅ Archive playback for any 1-hour window in the retention period.
5. ✅ Configurable end-to-end via web UI; no manual file edits after first boot.
6. ✅ Single-command per-host deploy: `nixos-rebuild switch --flake .#hnvr-{1,2}`.
7. ✅ Host failover: killing one host reassigns its cameras within 15 s.
8. ✅ Healthchecks, metrics, logrotate, NATS durability all wired.
9. ✅ RTX 4090 using TensorRT EP at < 2 ms/frame; ~~GTX 1070 using CUDA EP at < 6 ms/frame~~ → **criterion revised**: cuDNN ≥ 9.12 dropped Pascal, so hnvr-1 runs the CPU EP.
10. ✅ PTZ cameras manually controllable from web UI; presets saved/restored; idle return-to-home works.

## Definition of Done (v1.1 — auto-track milestone)

1. ✅ At least one PTZ camera can be put into auto-track mode and follow a walking person across the field of view.
2. ✅ Manual PTZ input preempts auto-track; resume requires explicit operator action.
3. ✅ Per-camera PID tuning panel works; admin can adjust gains without restarting.
4. ✅ Lost-target and return-home timeouts configurable per camera.
5. ✅ PTZ commands from auto-track audited in `ptz_audit_log` with `source='auto_track'`.
