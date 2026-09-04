# HNVR — Haskell Network Video Recorder

A self-hosted NVR for 6–20 RTSP/IP cameras, written in Haskell. HNVR
records every camera 24/7 to S3-compatible object storage, runs YOLOv8
object detection on the sub-stream, fires line-crossing / zone-intrusion
/ zone-motion events with video clips, and serves a web UI for live
view (WebRTC), archive playback, event review, ONVIF config sync, and
PTZ control. Multi-host: a leader coordinates, workers capture; all
nodes communicate over NATS.

![Dashboard — live wall](docs/screenshots/dashboard.png)

## Features

**Recording**
- 24/7 main-stream recording via ffmpeg (`-c:v copy` — no re-encode,
  negligible CPU) into 1-second fMP4 fragments, uploaded to S3.
- Local spool with automatic drain when S3 is unreachable — no gaps
  during storage outages.
- Per-camera retention (hours), hourly retention sweeper, tombstoned
  (verified) deletion of user-purged recordings.
- Optional per-camera audio track recording.

**Live view**
- Sub-second latency WebRTC (WHEP) via a MediaMTX sidecar; MediaMTX
  holds a single RTSP session per camera no matter how many viewers
  or pipelines attach.
- Dashboard live wall with per-camera status badges (REC / STARTING /
  RECONNECTING / FAILED / HOST DOWN), refreshed in-page. The wall
  auto-sizes: the column count (1, 2, 3 … per row) is chosen to
  maximize tile size while keeping the whole wall on one screen.
- Fullscreen overlay player, mouse-wheel zoom at cursor, drag-to-pan,
  double-click fullscreen — on every player in the app. All players
  and previews size themselves to the maximum the viewport allows.
- Dashboard and live view are anonymous-readable (optional kiosk /
  wall-monitor mode); everything else requires login.

**Archive timeline**
- One canvas timeline per camera fleet: coverage lanes, event markers,
  drag-to-scrub with hover snapshot previews (YouTube-style), and a
  single player with a camera switcher — deep-linkable
  (`/Timeline?from&to&t&active`).
- Prev/next event jump buttons; marker click seeks, shift-click opens
  the event clip; whole panel goes fullscreen with the strip intact.
- Playback is repaired client-side: EXTINF durations are rewritten
  from real fragment timestamps and legacy audio-clock skew is
  patched/stripped in the loader, so old recordings play smoothly.
- Admin window purge with tombstoned (verified) deletion.

**AI / events**
- YOLOv8 (n-320 or s-640, per-camera selectable) on ONNX Runtime —
  CPU, CUDA, or TensorRT execution providers with an on-disk TRT
  engine cache.
- SORT multi-object tracker (pure Haskell: Kalman filter + Hungarian
  assignment).
- Rules drawn directly on the camera frame: line crossing, zone
  enter/exit/inside, zone motion (moving objects only), with class
  filters, cooldowns, and per-rule enable.
- Event clips: pre-roll/post-roll video around each event, stored
  separately with their own retention; playable from the events table.
- Event thumbnails (Ken Burns animated, lightbox review), live event
  feed, full-text/bbox/class filtering.
- Rule changes propagate to nodes live over NATS — no restarts.

**PTZ (ONVIF Profile PT)**
- Hold-to-move directional pad, zoom, absolute moves, presets
  (save/goto/delete), home position, idle timeout with auto-return.
- Sliding side-drawer UI on both the dashboard overlay and the live
  page; rendered only for logged-in users.
- Per-camera command controller with audit log (every command
  recorded with source, user, and ok/error result) and Prometheus
  metrics.

**ONVIF config sync**
- Declare desired encoder settings (resolution/fps/bitrate/GOP/audio)
  per stream; HNVR clamps them against the camera's advertised
  options, pushes on save, and continuously reconciles drift
  (poller + per-camera drift table with badges).

**Operations**
- Multi-host: leader + any number of workers; automatic camera
  assignment with host-claim handshake (no duplicate recorders),
  manual pinning override.
- Prometheus metrics on every node (frames, inference latency, PTZ
  commands, S3 errors, process RSS), unauthenticated `/healthz` and
  `/status` endpoints.
- Audit log page: logins, camera/rule changes, purges, assignments.
- All timestamps render in the viewer's timezone (per-user profile
  setting, browser-local by default).
- Two UI themes (Midnight Ops dark / Daylight light), sortable and
  filterable tables throughout.
- Secrets via sops-nix; camera passwords stored AES-256-GCM
  encrypted; browser-facing S3 URLs are presigned with a separate
  read-only identity.

## Screenshots

| | |
|---|---|
| ![Live overlay (WebRTC)](docs/screenshots/live-overlay.png) | ![PTZ drawer](docs/screenshots/live-ptz-drawer.png) |
| Live WebRTC overlay | PTZ side-drawer with presets |
| ![Events](docs/screenshots/events.png) | ![Rule editor](docs/screenshots/rule-editor.png) |
| Event review with thumbnails | Rule editor (zones drawn on the live frame) |
| ![Archive timeline](docs/screenshots/timeline-playing.png) | ![Archive player](docs/screenshots/archive-player.png) |
| Archive timeline: coverage lanes, markers, scrub player | Windowed fMP4/HLS player, deep-linkable |
| ![Daylight theme](docs/screenshots/dashboard-daylight.png) | ![Hosts](docs/screenshots/hosts.png) |
| Daylight theme | Host fleet view |

Also: [login](docs/screenshots/login.png) ·
[cameras](docs/screenshots/cameras.png) ·
[camera detail](docs/screenshots/camera-detail.png) ·
[rules](docs/screenshots/rules.png) ·
[stats](docs/screenshots/stats.png) ·
[audit log](docs/screenshots/audit.png)

## Architecture

```
                        browsers
                       │        │
                  HTTP │        │ WebRTC (WHEP)
                       ▼        ▼
        ┌────────────────────────────────────────────┐
        │ LEADER HOST (e.g. hnvr-2)                  │
        │                                            │
        │  hnvr-leader (one binary, two roles):      │
        │    IHP web UI :8000                        │
        │    coordinator: assigns cameras to hosts   │
        │    writers: events / PTZ audit / health    │
        │    sweepers: retention, pending purges     │
        │    ONVIF config syncer (drift reconcile)   │
        │    embedded node roles (capture + CV + PTZ)│
        │    Prometheus /metrics :9100               │
        │                                            │
        │  mediamtx  RTSP→WebRTC  (:8889, API :9997) │
        │  nats-server            (:4222)            │
        └──┬───────────┬──────────────┬──────────────┘
           │           │ NATS         │
           │           ▼              │
           │  ┌──────────────────┐    │
           │  │ WORKER HOST(s)   │    │
           │  │ hnvr-node        │    │
           │  │  capture workers │    │
           │  │  CV analyzers    │    │
           │  │  PTZ controllers │    │
           │  │  health reporter │    │
           │  │  /metrics :9100  │    │
           │  └───────┬──────────┘    │
           ▼          ▼               ▼
      ┌─────────────────────────────────────┐      ┌──────────┐
      │ cameras (RTSP / ONVIF)              │      │ external │
      │  Hik-OEM, XM/OpenIPC, Majestic, ... │      │ services │
      └─────────────────────────────────────┘      │          │
                                                   │ PostgreSQL (config, events,│
      S3 object storage (SeaweedFS, MinIO, ...)    │ segments index, audit)     │
      ◄── all nodes put fMP4 fragments + clips ──► │ SeaweedFS S3 (video store) │
                                                   └──────────┘
```

Data flow, per camera:

1. MediaMTX pulls one RTSP session from the camera; HNVR configures
   and owns the MediaMTX paths via its REST API.
2. The assigned host's capture worker runs ffmpeg against the local
   MediaMTX relay, splits the stream into 1 s fMP4 fragments, and
   uploads them to S3 (`<slug>/<YYYY-MM-DD>/<HH-MM-SS.mmm>.mp4` +
   `init.mp4`). A ring buffer keeps the last N seconds for event clips.
3. In parallel, the analyzer decodes the sub-stream at
   `analysis_fps`, runs YOLO + SORT, and evaluates rules; rule hits
   become `CvEvent`s published on NATS.
4. The leader's writers persist events, clip metadata, health, and
   PTZ audit records to PostgreSQL.
5. The web UI serves live WebRTC, archive playlists (windowed fMP4
   over presigned URLs), event clips, and configuration.

Leader failover / HA leases are post-v1; today the leader is a single
point of coordination (capture continues on workers if the leader's
web tier is down, but reassignment stops).

## Tech stack

| | |
|---|---|
| Language | Haskell, GHC 9.12.3 |
| Web | IHP v1.6.0 (WAI + HSX), vanilla JS (`app.js`, `timeline.js`, `ptz.js`), Tailwind CLI |
| IPC | NATS (core; JetStream deferred) via vendored `nats-queue` |
| Capture | ffmpeg 7 subprocesses, fMP4 fragmentation in-process |
| CV | ONNX Runtime via internal FFI binding; YOLOv8n-320 / YOLOv8s-640; pure-Haskell SORT |
| PTZ | ONVIF SOAP client (WSSE + Basic), per-camera command loops |
| Storage | S3 via minio-hs (vendored, patched); PostgreSQL 18 |
| Live | MediaMTX v1.20.1 sidecar |
| Deploy | NixOS flake + modules, sops-nix secrets |

## Requirements

- **NixOS** (or Nix + systemd) on x86_64 Linux for the supported
  deployment path.
- One host designated leader; any number of workers. GPU optional:
  CPU inference works everywhere; TensorRT needs a recent NVIDIA GPU
  (cuDNN ≥ 9.12 requires compute capability ≥ 7.5 — Pascal and older
  fall back to the CPU EP).
- External services (operated by you): PostgreSQL 18, an
  S3-compatible store (SeaweedFS is the reference), one NATS server
  (or the bundled NixOS module on the leader).

## Configuration

### App config file (`hnvr.yaml`)

The single required config file; path from `$HNVR_CONFIG`
(default `./hnvr.yaml`). Template: [`hnvr.example.yaml`](./hnvr.example.yaml).

```yaml
s3:
  endpoint: "http://192.168.0.254:8333"        # server-side S3 API
  public_endpoint: "https://s3.example.com"    # browser-reachable (presign host)
  bucket: "hnvr"
  access_key: "ADMIN_KEY"        # server identity: Read/Write/List
  secret_key: "ADMIN_SECRET"
  ro_access_key: "RO_KEY"        # optional read-only identity used to
  ro_secret_key: "RO_SECRET"     # sign URLs handed to browsers
```

`HNVR_S3_*` env vars override the file per section. Unknown keys are
ignored, so the file can grow new sections ahead of the binaries.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `HNVR_CONFIG` | `./hnvr.yaml` | App config file path |
| `DATABASE_URL` | local socket | PostgreSQL DSN |
| `HNVR_NATS_URI` | — | NATS URI (**must** include `user:pass@`, even dummy) |
| `HNVR_HOST` | `hnvr-2` | This host's identity (assignment, health, claims) |
| `PORT` | `8000` | Web UI port (leader) |
| `HNVR_DATA_KEY` | — | base64 32-byte key encrypting camera passwords at rest |
| `INITIAL_ADMIN_EMAIL` / `INITIAL_ADMIN_PASSWORD` | — | Bootstrap admin (upserted at every boot) |
| `HNVR_METRICS_PORT` | `9100` | Prometheus endpoint (leader + node) |
| `HNVR_MODEL_PATH` / `HNVR_MODEL_DIR` | — | ONNX model file / per-camera model directory |
| `HNVR_EXEC_PROVIDERS` | `cpu` | EP priority, e.g. `tensorrt,cuda,cpu` |
| `HNVR_ONNXRUNTIME_LIB` | — | `libonnxruntime.so` to dlopen |
| `HNVR_TRT_CACHE_DIR` | — | TensorRT engine cache directory |
| `HNVR_MEDIAMTX_API` / `HNVR_MEDIAMTX_WEBRTC` / `HNVR_MEDIAMTX_CONFIG_PATH` | localhost defaults | MediaMTX sidecar wiring (leader) |
| `HNVR_SPOOL_DIR` | `/var/lib/hnvr/spool` | S3-outage fragment spool |
| `HNVR_S3_ENDPOINT` … `HNVR_S3_RO_SECRET_KEY` | — | Env-only S3 config (override the file) |
| `HNVR_DISABLE_*` | — | Per-component kill switches (`NODEROLES`, `COORDINATOR`, `EVENTWRITER`, `RETENTION`, `METRICS`, …) for bisecting problems |

### NixOS module (production)

```nix
{
  imports = [ hnvr.nixosModules.default ];

  services.hnvr.leader = {
    enable = true;
    hostName = "hnvr-2";               # this host's identity
    port = 8000;
    databaseUrl = "postgresql:///hnvr?host=/run/postgresql";
    natsUri = "nats://nats:nats@localhost:4222";
    configFile = config.sops.secrets.hnvr-config.path;  # hnvr.yaml content
    execProviders = "tensorrt,cuda,cpu"; # RTX 4090 leader
    modelDir = "/var/lib/hnvr/models";
    metricsPort = 9100;
    environment = {
      HNVR_DATA_KEY = "…";             # or via sops EnvironmentFile
      INITIAL_ADMIN_EMAIL = "admin@example.com";
      INITIAL_ADMIN_PASSWORD = "change-me";
    };
  };

  # Companion modules (leader host):
  services.hnvr.nats.enable = true;      # bundled broker
  services.hnvr.mediamtx.enable = true;  # RTSP→WebRTC sidecar
}
```

Worker hosts run the `hnvr-node` binary with `HNVR_HOST`,
`HNVR_NATS_URI` pointing at the leader, and the same `HNVR_CONFIG` /
model env vars — no database access needed on workers. **Never run
`hnvr-node` on the leader host** — the leader binary already embeds
the node role; a host-claim handshake refuses the duplicate.

Secrets: [`nix/secrets-template.yaml`](./nix/secrets-template.yaml) —
one sops key (`hnvr-config`) holds the whole YAML; `HNVR_DATA_KEY` and
`DATABASE_URL` are separate keys.

## Deployment

The flake ships two reference VMs (`hnvr-1-vm` worker, `hnvr-2-vm`
leader) that double as integration rigs:

```bash
nix build .#nixosConfigurations.hnvr-2-vm.config.system.build.vm
NIX_DISK_IMAGE=/tmp/leader.qcow2 \
QEMU_NET_OPTS="hostfwd=tcp:127.0.0.1:18000-:8000,hostfwd=tcp:127.0.0.1:18889-:8889,hostfwd=tcp:127.0.0.1:19997-:9997" \
  ./result/bin/run-nixos-vm
curl http://localhost:18000/healthz    # → 200 OK
```

For real hosts, import the modules and set options as above;
`nix/module.nix` manages the systemd unit (user, data dir, static
assets, `LimitNOFILE`, restart policy).

## Web UI map

| Route | Auth | Purpose |
|---|---|---|
| `/` (`/Dashboard`) | anonymous | Live wall + host fleet summary |
| `/ShowLive?cameraId=…` | anonymous | Full-page WebRTC live view |
| `/Events` | login | Event table: filters, thumbnails, clip replay |
| `/Timeline` | login | Archive timeline: coverage lanes, event markers, scrub player, purge |
| `/PlayerArchive?cameraId=…&from&to&t` | login | Windowed fMP4/HLS player, deep-linkable |
| `/PlayerEventClip?clipId=…` | login | Event clip player |
| `/Cameras`, `/NewCamera`, `/EditCamera`, `/ShowCamera` | login | Camera CRUD, probe, assignment, ONVIF drift |
| `/Rules`, `/NewRule`, `/EditRule` | login | Rule editor with on-frame geometry canvas |
| `/PtzPresets` | login | Preset management |
| `/Stats` | login | Storage + event statistics |
| `/Hosts` | login | Fleet status, GPU, liveness |
| `/AuditLog` | admin | Full audit trail |
| `/ShowProfile` | login | User profile (timezone) |
| `/DebugCamera?cameraId=…` | login | Live analysis overlay (bbox + track IDs) |
| `/healthz`, `/status` | anonymous | Liveness probe / version JSON |
| `/whep/<slug>` | anonymous | WebRTC signaling proxy to MediaMTX |
| `/metrics` (port 9100) | scrape | Prometheus text format |

## Development

```bash
nix develop --no-pure-eval   # devenv-integrated shell (direnv works too)
devenv up                    # postgres :15432, nats :4222, mediamtx :9997
nix build .#hnvr-web         # the app (IHP needs the nix overlay)
./result/bin/hnvr-leader     # http://localhost:18001 (env pre-wired)

cabal build hnvr-core hnvr-nats hnvr-storage hnvr-capture hnvr-cv hnvr-ptz
cabal test hnvr-core hnvr-nats hnvr-storage hnvr-capture hnvr-cv hnvr-ptz
HNVR_TEST_INTEGRATION=1 HNVR_CONFIG=$PWD/hnvr.yaml cabal test hnvr-nats hnvr-storage

cd tests/e2e && npm install && npx playwright install chromium   # one-time
npm test                                                        # 35 specs

nix build .#checks.x86_64-linux.pre-commit                      # ormolu/hlint/etc
nix build .#checks.x86_64-linux.hnvr-leader-smoke               # NixOS VM smoke test
```

`cabal build hnvr-web` is unsupported — IHP's transitive pins only
exist in the nix overlay; always `nix build .#hnvr-web`.

## Repository layout

```
├── hnvr-core/      shared types + pure logic (segments, rules, crypto, assignment)
├── hnvr-nats/      NATS bus wrapper + subject taxonomy
├── hnvr-storage/   S3 wrapper (minio-hs) + hnvr-s3-upload tool
├── hnvr-capture/   ffmpeg/fMP4 pipeline, worker state machine, ring buffer, spool
├── hnvr-cv/        ONNX Runtime FFI, preprocess/decode, SORT tracker, rules engine
├── hnvr-ptz/       ONVIF + DVRIP clients, per-camera PTZ controller
├── hnvr-web/       IHP app: controllers, views, node/leader roles, migrations
├── nix/            NixOS modules (leader, NATS, MediaMTX, secrets template)
├── tests/e2e/      Playwright suite + scripts/screenshots.mjs
├── design_docs/    authoritative design (00-overview … 12)
├── vendored/       nats-queue + minio-hs (patched)
└── docs/screenshots/  README images
```

## Status

Current version **0.16.0.0** (pre-release). Phases 0–5 shipped:
recording, live view, multi-host, CV pipeline, events + clips, ONVIF
config sync, PTZ — plus the unified archive timeline (canvas scrubbing,
single switchable player, client-side legacy-recording repair) and the
auto-sizing live wall. Post-v1 roadmap: leader HA lease, auto-track
(closed-loop PID), clip export jobs, viewer role. See
[`design_docs/08-roadmap.md`](./design_docs/08-roadmap.md).

Tests: 449 Haskell unit/property tests, 35 Playwright specs, 1 NixOS VM
smoke test. CI: flake check + builds on every push, nightly Playwright.

## Conventions

- No comments unless requested.
- Ormolu (Haskell) + nixpkgs-fmt (Nix), enforced via pre-commit.
- Secrets never committed — sops-nix; `hnvr.yaml` is gitignored.
- Design docs are authoritative: start at
  [`design_docs/00-overview.md`](./design_docs/00-overview.md).
