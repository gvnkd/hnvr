# HNVR — Tech Stack

Versions are the latest known-good as of Aug 2026. Pinned in `flake.lock`.

## Core Haskell

| Library | Version | Why |
|---------|---------|-----|
| `base` | **GHC 9.12** (nixpkgs `haskell.compiler.ghc912`) | Sergey's choice. IHP experimental. Bleeding edge. |
| `cabal` | 3.14+ | Build system; one cabal.project, multiple sublibs. |
| **`ihp`** | flake-pinned to commit on `master` with 9.12 support | Schema designer, autorefresh, sessions, CSRF, hsx. The `v1.5` release supports up to 9.8 — must use `master` HEAD for 9.12. |
| `text`, `bytestring`, `vector`, `containers` | nixpkgs | Baseline. |
| `async` | 2.2.x | Worker threads. |
| `stm` | 2.5.x | Bounded `TChan`s, MVar coordination. |
| `unliftio` / `safe-exceptions` | 0.2.x | Bracketed resource handling. |
| `resource-t` | 1.3.x | Bracket ffmpeg + NATS connections through worker lifetime. |
| `monad-logger` / `fast-logger` | 0.8 / 3.2 | Structured logs, one file per worker. |
| `ekg-core` | 0.1.2 | Metric store only; Prometheus text rendered in-tree (`Hnvr.Core.Metrics`), own warp on `:9100` (`HNVR_METRICS_PORT`). |
| `aeson`, `aeson-pretty` | 2.2+ | JSON for events, NATS payloads, frontend. |
| `time` | 1.12+ | ISO8601 timestamps. |
| `optparse-applicative` | 0.18+ | CLI flags for binaries. |
| `memory`, `cryptonite` | 0.18 / 0.30 | AES-256-GCM for camera passwords at rest. |
| `linear` | 1.22+ | 2D vector / segment math for line crossing. |
| `massiv` | 1.0+ | Stencil-friendly arrays for resize / NHWC→NCHW / normalize. |

## NATS

| Library | Version | Why |
|--------|---------|-----|
| **`nats-queue`** (Haskell) | git HEAD (Hackage unstable) | Pure-Haskell NATS client with JetStream support. Vendored in `flake.nix`; expect some patching. |
| *Alternative:* `hs-nats` | git HEAD | Newer, less battle-tested; consider if `nats-queue` proves brittle. |
| *Fallback:* `natsonline` Go binary wrapped via subprocess | n/a | Only if both Haskell clients are unworkable — would be ugly. |

**NATS server**: deploy `nats-server` 2.10+ in our NixOS scope (not SaaS — Sergey confirmed we run it). Single node in v1, clusterable post-v1.

## Stream ingestion

| Tool | Version | Why |
|------|---------|-----|
| **ffmpeg** | **7.x** (nixpkgs `ffmpeg_7-full`) | Subprocess per camera. Hardware accel via `-hwaccel cuda|vaapi|qsv` flags. |
| `typed-process` | 0.2.x | Type-safe process spec; cleaner than raw `createProcess`. |
| `bytestring` Builder | base | Accumulate fMP4 fragment bytes. |

**NOT using** `ffmpeg-light` (0.14.1, GHC 9.2 ceiling). Subprocess piping is more robust and gets free hardware acceleration through ffmpeg.

**NOT using** `hw-rs` or any pure-Haskell RTSP client. RTSP/RTP re-implementation is out of scope.

**Sub-stream discovery (v1: manual; post-v1: ONVIF)** — In v1, the admin probes the sub-stream URL with `ffprobe` and fills `rtsp_sub_url` manually. Post-v1, add an ONVIF SDD probe via the `hnvr-ptz` ONVIF client (described below) to auto-discover both main + sub stream URLs and supported resolutions.

## PTZ (Pan/Tilt/Zoom)

| Library | Version | Why |
|---------|---------|-----|
| **`hnvr-ptz`** (vendored sublib) | n/a | New sublib: ONVIF client + PTZ state machine + driver abstraction. |
| `http-conduit` / `http-client` | 2.3 / 0.7 | ONVIF is SOAP over HTTP; need session-aware client with timeouts. |
| `xml-conduit` | 1.9 | Parse ONVIF SOAP XML responses. Build requests via `blaze-html` or `Builder`. |
| `cryptonite` | 0.30 | WS-Security UsernameToken (SHA-1 digest of password + nonce + UTC timestamp). |
| `chronos` | 1.1 | ISO8601 timestamps for WS-Security header. |

**NOT using** any Hackage ONVIF package — none are mature/maintained. Hand-rolled SOAP client for the PTZ subset we need (~500 LOC), covering these ONVIF operations:

- `GetServices` / `GetCapabilities` (device service) — discover PTZ service URL
- `GetPresets`, `GotoPreset`, `SetPreset`, `RemovePreset`
- `ContinuousMove`, `Stop` (for manual joystick)
- `AbsoluteMove` (for `goto_preset` and home return)
- `RelativeMove` (optional)
- `GetStatus` (current position polling, optional)
- `GetConfigurations` (probe ranges + speed limits at config time)

### Driver abstraction

```haskell
class PtzDriver m where
  continuousMove :: CameraId -> Velocity -> TimeoutMs -> m ()
  stop           :: CameraId -> StopAxes -> m ()
  gotoPreset     :: CameraId -> PresetToken -> m ()
  setPreset      :: CameraId -> PresetName -> m PresetToken
  removePreset   :: CameraId -> PresetToken -> m ()
  getStatus      :: CameraId -> m (Maybe PtzStatus)

data Velocity = Velocity { vPanTilt :: !(V2 Float), vZoom :: !Float }
```

Single instance in v1: `OnvifPtzDriver`. Adding a vendor-CGI driver later (e.g. for non-ONVIF cameras) is a new instance, no upstream changes.

**ONVIF endpoint discovery**: when admin saves `ptz_onvif_url` in the UI, leader runs `GetCapabilities` → finds PTZ service URL → caches it in `cameras.ptz_onvif_url` (rewritten to the actual service endpoint). All subsequent PTZ calls hit the cached URL.

**Authentication**: ONVIF uses WS-Security UsernameToken in SOAP header. SHA-1 digest of `base64(nonce) + created_timestamp + plaintext_password`. Reuse camera username/password if `ptz_username` is null.

## Computer vision

| Library | Version | Why |
|---------|---------|-----|
| **Internal ONNX Runtime binding** (`Hnvr.Cv.OnnxRuntime`) | ~150 LOC vendored | `hs-onnxruntime-capi` is too stale on Hackage. The ONNX Runtime C API is a single vtable struct, stable across versions — write the binding ourselves. |
| `onnxruntime` (C lib) | **1.18+** via `nixpkgs.onnxruntime` | The actual `.so`. CUDA EP requires `cudaPackages`; TensorRT EP requires `tensorrt`. |
| `cudaPackages` (Nix) | 12.x | For GTX 1070 + RTX 4090. |
| `tensorrt` (Nix) | 10.x | RTX 4090 only (Ada support); does NOT work on Pascal. |
| `JuicyPixels` | 3.3.x | PNG-encode preview thumbnails. |
| `massiv` | 1.0+ | Frame preprocess. |
| `linear` | 1.22+ | Tracker math. |
| `containers` (`IntMap`, `Seq`) | base | SORT tracker state. |
| `mwc-random` | 0.15 | SORT init jitter. |

### YOLO model

- **YOLOv8n** (nano) ONNX, input `1×3×320×320`, output `[1,84,2100]` pre-NMS.
- Export with `yolo export model=yolov8n.pt format=onnx imgsz=320 opset=17 simplify=True dynamic=False`.
- Default kept classes: `[0,1,2,3,5,7]` (person, bicycle, car, motorcycle, bus, truck), configurable per rule.

**Per-host defaults:**

| Host | Model | EP | Approx. fps |
|------|-------|----|----|
| hnvr-1 (GTX 1070) | YOLOv8n-320 | CUDA | ~200 |
| hnvr-2 (RTX 4090) | YOLOv8n-320 (default) / YOLOv8s-640 (optional) | TensorRT | ~1000 / ~400 |

For TensorRT, ship a pre-converted `.engine` plan alongside the `.onnx`. ONNX Runtime will load the engine directly if present, otherwise build one on first run (cached under `/var/lib/hnvr/engines/`).

### Tracker (pure Haskell)

SORT (Bewley et al. 2016) in `Hnvr.Cv.Tracker.Sort`: ~250 LOC. Kalman filter with constant-velocity state `[x,y,s,r,dx,dy]`; Hungarian assignment via `hungarian-algorithm-1.0.0`; birth = 3 consecutive hits, death = 30 missed.

## Storage

| Library | Version | Why |
|---------|---------|-----|
| **`minio-hs`** | nixpkgs pin | S3-compatible client (SeaweedFS, MinIO). Path-style addressing by default — exactly what SeaweedFS needs. Replaces the originally-planned `amazonka-s3` (which doesn't compile under GHC 9.12 without source patches — see MEMORIES.md pitfall #28). Same operations surface (putObject/getObject/presignUrl/listObjects/removeObject). |
| **PostgreSQL 18** (external SaaS) | n/a — connect via env URL | Async I/O, virtual generated columns, improved logical replication. IHP uses libpq, fully compatible. |
| IHP's bundled `postgresql-libpq` | IHP-managed | Don't add `postgresql-simple` or `persistent` — IHP owns the DB layer. (HNVR's leader-side LISTEN/NOTIFY loops and migrations DO use `postgresql-simple` directly, outside IHP's Hasql pool, because Hasql 1.9.x has no Notification module and IHP v1.6.0's `sqlExec` is broken for DDL — see pitfalls #41, #42.) |

**SeaweedFS / MinIO specifics**
- Connection params come from the YAML app config (`hnvr.yaml`, path via `HNVR_CONFIG`; see `hnvr.example.yaml`). `HNVR_S3_*` env vars remain as per-field overrides (tests, one-off binaries).
- Browser-facing presigned URLs use `public_endpoint` (or `HNVR_S3_PUBLIC_ENDPOINT`) when set; the signed URL's host is part of the SigV4 signature, so an internal `localhost` endpoint would otherwise leak into archive playlists and event thumbnails. Falls back to `endpoint`. Use `scheme://host[:port]` (no path prefix).
- Presigned URLs handed to browsers are signed with the read-only `ro_access_key`/`ro_secret_key` identity when configured (SeaweedFS `Read`/`List` actions only) — the admin key never leaves the server.
- Path-style addressing — minio-hs default; no virtual-hosted-style.
- Lifecycle policies: SeaweedFS supports per-bucket TTL, but we sweep ourselves via `Hnvr.Web.RetentionSweeper` (M6, Aug 11 2026) — don't rely on it.
- Erasure coding is internal to SeaweedFS — we just see a normal S3 API.

**Postgres 18 specifics we use**
- Virtual generated columns for derived fields (e.g. `start_date AS (start_ts::date) STORED` — actually `STORED`, since PG 18 still rolls out virtual GCs).
- BRIN indexes (since PG 9.5) — already in our schema.
- Async I/O backend on the SaaS side, transparent to us.
- `pg_partman` extension available on the SaaS for partition management.

## Web / live view

| Library / tool | Version | Why |
|----------------|---------|-----|
| **IHP** | pinned `master` commit supporting GHC 9.12 | Schema designer, hsx templates, autorefresh, sessions, CSRF. |
| `wai-websockets` | 3.0 | Optional; IHP autorefresh via SSE is preferred for live event feeds. |
| **MediaMTX** | **v1.20.0** | Single Go binary, packaged via flake input pinned by revision. RTSP → WebRTC WHEP, HLS. **Runs on leader host only.** |
| `hls.js` (vendored via IHP `static/`) | 1.5+ | Fallback for browsers without HEVC-over-WebRTC. |
| `chart.js` + htmx (vendored) | latest | Dashboard charts; htmx partial refresh. |
| WHEP client (`/static/whep.js`) | ~50 LOC, browser-native | RTCPeerConnection + fetch SDP; no npm. |

## Build & dev

| Tool | Version | Why |
|------|---------|-----|
| **Nix flake** | nix 2.24+ | Lockfile-driven; per-host NixOS configs in one flake. |
| `pre-commit-hooks.nix` | latest | `ormolu`, `hlint`, `nixpkgs-fmt`, `cabal-fmt`. |
| `haskell-flake` | latest | Per-sublib devshells + a combined one. |
| `direnv` + `nix-direnv` | latest | Auto-loading shell. |
| `nixos-generators` (optional) | latest | For VM tests in CI. |

### Cabal project layout

```haskell
-- cabal.project
packages:
  ./hnvr-core
  ./hnvr-nats
  ./hnvr-capture
  ./hnvr-cv
  ./hnvr-storage
  ./hnvr-web

allow-newer:
  amazonka-s3:base,
  amazonka-core:base,
  massiv:base,
  ihp:*
  -- ... add as needed for GHC 9.12

package hnvr-web
  flags: +dev  -- IHP live reload in dev only
```

The flake uses `haskell-flake` to derive per-sublib devShells + a single combined shell that includes ffmpeg, onnxruntime, nats-server, mediamtx (for local testing).

## GHC 9.12 jailbreaks (likely required)

In `flake.nix`, override these haskellPackages with `jailbreakCabal` + `overrideCabal`:

```nix
hpkgsOverlays = final: prev: {
  amazonka-core   = lib.pipe prev.amazonka-core   [ lib.haskellPackages.jailbreakCabal ];
  amazonka-s3     = lib.pipe prev.amazonka-s3     [ lib.haskellPackages.jailbreakCabal ];
  # ... extend as CI discovers upper-bound failures
};
```

This is the pragmatic cost of running GHC 9.12 in Aug 2026. Track upstream releases; remove overrides as packages publish compatible revisions.

## Alternatives considered (and rejected)

| Concern | Alternative | Rejection reason |
|---------|-------------|------------------|
| Compiler | GHC 9.10 (IHP stable) | Sergey explicitly picked 9.12. |
| IPC | In-process `TChan` only (no NATS) | Can't scale to 2+ hosts; Sergey wants horizontal scale design. |
| IPC | RabbitMQ | Heavier; JetStream covers durability; NATS is simpler. |
| IPC | Redis Streams | Workable but NATS subject model is a better fit for pub-sub commands. |
| IPC | ZeroMQ | No broker; would have to invent leader election; lose durability. |
| CV runtime | Python sidecar (Ultralytics + FastAPI) | Sergey explicitly picked ONNX-via-FFI; second language is unwanted. |
| CV runtime | `opencv-ghc` | Stale; OpenCV DNN slower than ONNX Runtime for YOLO. |
| Live view | Pure-Haskell WebRTC | Immature; not worth it. |
| Live view | HLS-only | 5–30 s latency unacceptable for live monitoring. |
| Storage | In-scope MinIO | Sergey explicitly: S3 + PG out of scope as SaaS. |
| Storage | Local FS + SQLite | Sergey picked SeaweedFS; SQLite bad fit for distributed writers. |
| Tracker | ByteTrack | Marginal accuracy gain over SORT; double the code. |
| Process supervision | `capability` / `eventuo11y` | Keep simple; supervision tree is shallow. |

## Pinning policy

- **Hackage deps**: pinned by `cabal.project.freeze` regenerated quarterly; CI verifies `cabal build all`.
- **External flake inputs**: `nixpkgs` (rolling, locked), `ihp` (`master` commit, locked), `mediamtx` (GitHub release tarball + sha256), `nats-server` (nixpkgs).
- **Models**: SHA256-pinned in Nix derivation (`fetchurl`).
- **TensorRT engines**: SHA256-pinned per `(model, gpu_arch, trt_version)` triple; built offline and shipped as Nix artifacts.
