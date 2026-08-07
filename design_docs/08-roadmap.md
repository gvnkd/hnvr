# HNVR — Roadmap

Phased delivery. Each phase ends with a demonstrable, deployable system. Two hosts throughout: hnvr-1 (GTX 1070, worker), hnvr-2 (RTX 4090, leader).

## Phase 0 — Bootstrap (week 1)

Goal: two NixOS VMs build and run the binaries, NATS connected, IHP returns `/healthz`.

- [ ] `flake.nix` with `haskell-flake` + IHP pinned to a GHC 9.12-capable commit
- [ ] GHC 9.12 jailbreak overlay (`amazonka-core`, `amazonka-s3`, others as discovered by CI)
- [ ] `ihp new hnvr-web` skeleton
- [ ] `nix/module.nix` minimal (one binary, no GPU, no NATS yet)
- [ ] `nix/nat-server.nix` (single-node NATS with JetStream)
- [ ] `hnvr-nats` sublib: connection pool, basic pub/sub, JetStream helpers, JSON codecs
- [ ] `devShell.nix` with cabal, ghcid, ormolu, hlint, nats-server, mediamtx
- [ ] `pre-commit-hooks.nix` config
- [ ] CI: `nix flake check` + `cabal build all` on push (matrix GHC 9.10 sanity + 9.12 target)
- [ ] `healthz` action returning 200

**Demo**: two NixOS VMs (`nix run .#nixosConfigurations.hnvr-1-vm` / `hnvr-2-vm`) come up; `curl hnvr-2:8000/healthz` returns 200; NATS monitoring shows both connected.

## Phase 1 — Recording MVP (weeks 2–3)

Goal: camera in → fMP4 fragments in SeaweedFS → row in `segments` table → archive playback in browser.

- [ ] `hnvr-core`: `CameraId`, `Box`, `Sha256`, `HostId`, `UTCTime` helpers, structured logging
- [ ] `hnvr-storage`: SeaweedFS client wrapper (amazonka-s3 with path-style), segment publish
- [ ] `hnvr-capture`:
  - [ ] fMP4 fragmenter (~80 LOC parser)
  - [ ] `CaptureWorker` state machine
  - [ ] Recording ffmpeg invocation (main stream, `-c:v copy`)
  - [ ] SeaweedFS put + `SegmentWritten` publish on `hnvr.events`
  - [ ] Backoff / supervision
- [ ] `hnvr-leader` EventWriter: consume `hnvr.events`, filter `kind='segment_written'`, insert into `segments`
- [ ] IHP `cameras` CRUD (admin only); `assigned_host` auto-assigned by `AssignmentCoordinator`
  - [ ] Sub-stream fields: `rtsp_sub_url`, `rtsp_sub_template`, `use_substream_for_analysis`, etc.
  - [ ] "Probe sub-stream" button in UI (runs `ffprobe` server-side, fills dims + codec)
- [ ] IHP `archive` action: m3u8 generation, presigned URLs
- [ ] `<video>` + hls.js on archive page
- [ ] Camera password encryption (`hnvr-core/Crypto.hs`)
- [ ] sops-nix integration for `hnvr-data-key` + S3 creds + PG URL

**Demo**: Sergey adds one camera via UI; main stream + sub-stream both probe successfully; sees a 1-hour playback window with seek.

**Out of scope for Phase 1**: live view, CV inference, audio, retention sweep, exports, multi-host failover.

## Phase 2 — Live View + Multi-Host (week 4)

Goal: low-latency live view in browser; second host carries half the cameras.

- [ ] Add `mediamtx` flake input + `systemd.services.mediamtx` (leader only)
- [ ] `MediaMTXConfigSyncer`:
  - [ ] Postgres LISTEN on `cameras_events`
  - [ ] Render `mediamtx.yml` with credentials
  - [ ] SIGHUP mediamtx
- [ ] `/live/<slug>` view + WHEP client JS
- [ ] `/whep/<slug>` reverse proxy
- [ ] nginx config for WHEP
- [ ] **Multi-host:**
  - [ ] `AssignmentCoordinator` on leader
  - [ ] `hnvr.commands.assign.<cam>` + `hnvr.commands.control.<host>.<cam>.<action>`
  - [ ] `ConfigWatcher` per host subscribes `hnvr.config.>`
  - [ ] Health publication `hnvr.health.<host>` every 5 s
- [ ] Dashboard with camera grid + per-host panel
- [ ] Camera assignment UI (`POST /cameras/:id/assign`)

**Demo**: 6 cameras split 3/3 across hnvr-1 + hnvr-2; kill hnvr-1; cameras reassigned to hnvr-2 within 15 s; live view keeps working.

## Phase 3 — CV: detection + tracking (weeks 5–6)

Goal: YOLOv8n detections with persistent track IDs, visible in a debug overlay, on **both** hosts with appropriate EPs.

- [ ] `hnvr-cv/OnnxRuntime.hs`: minimal internal C API binding (~150 LOC) — no Hackage dep
- [ ] `Hnvr.Cv.Preprocess`: `massiv` letterbox (any input → 320×320) + normalize
- [ ] `Hnvr.Cv.Decode`: YOLOv8 anchor decode + NMS
- [ ] `Hnvr.Cv.Tracker.Sort`: Kalman + Hungarian
- [ ] `AnalyzerWorker` glue (consumes sub-stream Frame TChan from CaptureWorker)
- [ ] EP selection from `HNVR_EXEC_PROVIDERS`:
  - [ ] hnvr-1: CUDA EP (Pascal)
  - [ ] hnvr-2: TensorRT EP with pre-built `sm_89` engine (Ada)
- [ ] CI job to pre-build TensorRT engines via `trtexec`
- [ ] Debug view `/debug/<slug>` showing live frame with bbox overlay + track IDs (MJPEG over WebSocket, dev-only)
- [ ] EKG metrics: `hnvr_frames_decoded_total`, `hnvr_inference_seconds{ep}`, `hnvr_gpu_memory_used_bytes`, `hnvr_substream_fallback_total`

**Demo**: open `/debug/cam-196`, see bounding boxes following people; EKG shows ~1 ms inference on hnvr-2, ~5 ms on hnvr-1. Disable sub-stream on the camera → analyzer auto-falls-back to main-stream-with-scale; alarm counter increments; recording unaffected.

**No events yet** — just proves the pipeline end-to-end.

## Phase 4 — Events: line crossing + zone intrusion (weeks 7–8)

Goal: emit and persist events; UI for rules and events.

- [ ] `rules` table + CRUD UI (line drawing on a still frame)
- [ ] `Hnvr.Cv.Rules` engine (segment intersect, point-in-polygon)
- [ ] Per-rule cooldown state in analyzer
- [ ] `AnalyzerWorker` publishes events on `hnvr.events`
- [ ] Leader's `EventWriter` consumes CV events (in addition to `segment_written`) → Postgres
- [ ] `events` table + indexes
- [ ] `/events` view with filters
- [ ] Event thumbnails (JuicyPixels bbox draw + SeaweedFS put)
- [ ] Click event → deep-link to `/archive/<slug>?t=<ts>`
- [ ] Live event feed on `/live/<slug>` (autoRefresh)
- [ ] Audit log

**Demo**: draw a line across a doorway; person walks through; event appears in UI and live feed; click plays the second of the crossing.

## Phase 5 — PTZ manual control + presets (weeks 9–10)

Goal: full manual PTZ from the web UI; preset management; idle return-to-home.

- [ ] `hnvr-ptz` sublib:
  - [ ] ONVIF SOAP client (~500 LOC, hand-rolled, no Hackage dep)
  - [ ] WS-Security UsernameToken auth (SHA-1 digest)
  - [ ] `PtzDriver` typeclass
  - [ ] Operations: GetServices, GetPresets, GotoPreset, SetPreset, RemovePreset, ContinuousMove, Stop, AbsoluteMove, GetStatus, GetConfigurations
- [ ] `PtzController` per PTZ-enabled camera (one async thread)
- [ ] PTZ state machine (Idle, ManualMove, GoingToPreset, ReturningHome)
- [ ] NATS subjects: `hnvr.commands.ptz.<cam>`, `hnvr.ptz.status.<cam>`
- [ ] `ptz_presets` + `ptz_audit_log` tables
- [ ] Camera config: `ptz_enabled`, `ptz_onvif_url`, `ptz_profile_token`, `ptz_home_preset_id`, `ptz_idle_timeout_s`, `ptz_viewer_control`
- [ ] IHP:
  - [ ] `POST /cameras/:id/ptz` action (publishes NATS command)
  - [ ] `/cameras/:slug/presets` CRUD UI
  - [ ] "Probe ONVIF" button on camera edit (calls GetCapabilities, fills ptz_onvif_url + profile_token)
- [ ] Live view PTZ panel (joystick + zoom + preset dropdown)
  - [ ] `static/ptz.js` (~80 LOC vanilla JS)
  - [ ] PTZ status indicator via autoRefresh
- [ ] Idle timeout → return to home preset
- [ ] Audit log of every PTZ command
- [ ] EKG metrics: `hnvr_ptz_commands_total{cam,command,source}`, `hnvr_ptz_command_seconds`

**Demo**: open live view of a PTZ camera, drag joystick to pan, click preset to jump to saved position, idle for 30 s → camera returns to home preset. Disable PTZ via UI toggle → control panel disappears.

This is the **v1.0 release**. Tag it. Ship it.

## Phase 6 — Operational hardening (weeks 11–12)

- [ ] `RetentionSweeper` hourly cron (leader)
- [ ] `recording_gaps` detection on segment loss
- [ ] Export jobs (`POST /archive/<slug>/clip`)
- [ ] Prometheus dashboard JSON for Grafana (capture + CV + NATS + GPU + PTZ)
- [ ] Healthcheck + alerting hooks (webhook out on `FailedPermanent`)
- [ ] Logrotate integration
- [ ] Hardened systemd unit (full sandbox matrix)
- [ ] NATS JetStream stream config tuning (max age, max msgs, replication)
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

- [ ] Standby web node on hnvr-1 (leader election via JetStream KV)
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
| Does NATS JetStream handle our event rate (25 msgs/sec)? | Phase 4 — if not, batch events before publish |
| Can we drop `segment_written` events to halve NATS traffic? | Phase 6 — workers write directly to PG if JetStream chokes |
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
9. ✅ RTX 4090 using TensorRT EP at < 2 ms/frame; GTX 1070 using CUDA EP at < 6 ms/frame.
10. ✅ PTZ cameras manually controllable from web UI; presets saved/restored; idle return-to-home works.

## Definition of Done (v1.1 — auto-track milestone)

1. ✅ At least one PTZ camera can be put into auto-track mode and follow a walking person across the field of view.
2. ✅ Manual PTZ input preempts auto-track; resume requires explicit operator action.
3. ✅ Per-camera PID tuning panel works; admin can adjust gains without restarting.
4. ✅ Lost-target and return-home timeouts configurable per camera.
5. ✅ PTZ commands from auto-track audited in `ptz_audit_log` with `source='auto_track'`.
