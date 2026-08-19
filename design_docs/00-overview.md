# HNVR — Overview

## What this is

HNVR is a Network Video Recorder for 6–20 IP cameras (RTSP, mostly HEVC/H.264 at 4K and below) that records 24/7, runs ONNX-based object detection on the live stream, fires **line-crossing / zone-intrusion** events, and exposes a web UI for live view, archive playback, event search, and configuration.

The whole thing is written in Haskell, packaged as a NixOS flake, deployed across **two Nvidia-equipped hosts**. Workers communicate over a NATS bus. Storage (S3 + Postgres) is provided as an external SaaS (SeaweedFS + Postgres 18) and is **out of scope** for this project.

## Goals

| # | Goal | Verification |
|---|------|--------------|
| G1 | 24/7 RTSP recording with zero-frame-loss under nominal network | Segment gap check in `recordings` table |
| G2 | Sub-second latency live view in browser | WebRTC WHEP via MediaMTX; target <1s glass-to-glass |
| G3 | Detect line crossing / zone intrusion events on chosen cameras | Event rows in `events` table with bbox overlay stored |
| G4 | Time-aligned archive scrub across all cameras, ≥ 7-day retention | HLS playlist assembly from MP4 fragments |
| G5 | Configurable via web UI (cameras, zones, rules, retention) | IHP CRUD on all config tables |
| G6 | Single-command deploy per host via NixOS flake | `nixos-rebuild switch --flake .#<host>` brings whole stack up |
| G7 | Graceful degradation: a camera going offline must not crash the recorder or other cameras | Per-camera `async`-supervised worker, NATS health bus |
| G8 | Horizontal scale: capture + analysis workers can run on either host; camera-to-host assignment is dynamic | Web node can reassign a camera to a different host without service restart |

## Non-goals (v1)

- In-scope deployment of Postgres or S3 (provided as SaaS).
- Clustered/HA NATS in v1 (single NATS node, can be promoted to cluster post-v1).
- Face recognition / license plate recognition. (Model plug-in points exist, but no shipped models.)
- Cloud offsite sync of segments (manual `rclone` job against SeaweedFS is fine for v1).
- Mobile native app (responsive web only).
- Audio analytics (audio is recorded but not analyzed).
- Per-user RBAC beyond admin vs. viewer.
- **Auto-track closed loop** (ships in v1.1, see `04-cv-pipeline.md`).
- **Scheduled PTZ tours/patrols** (post-v1.1).
- Browser support beyond modern Chrome/Firefox (no Safari HEVC quirk handling in v1).

## Cameras observed (driving the design)

| IP | Codec | Res | FPS | Audio | Auth URL pattern |
|----|-------|-----|-----|-------|------------------|
| 192.168.0.196 | HEVC | 4000×3000 | 15 | pcm_mulaw 16k | `user=admin&password=...&channel=0&stream=MainStream` |
| 192.168.0.197 | H.264 | 3840×2160 | 15 | pcm_mulaw 16k | same scheme |
| 192.168.0.198 | HEVC | 2592×1520 | 15 | pcm_alaw 8k  | query-style `/stream=0` (main) / `/stream=1` (sub) — reflashed to **OpenIPC/Majestic** (imx335); static IP, ONVIF on port 80 |

**Implications**
- Two URL schemes (`stream=MainStream` query-param style vs Majestic's `/stream=0`) — stored verbatim in the per-camera `rtsp_url` field (the templating idea was dropped).
- HEVC dominant — segmenter produces `mp4` with `hev1` box (ffmpeg native); HLS playback via `hls.js` in Chrome (no Safari in v1).
- 4K HEVC @ 25 fps ≈ 2–4 GB/hr/cam. 20 cams × 7 days ≈ **7–14 TB** hot storage in SeaweedFS.
- Audio is mu-law/a-law — keep muxed, don't transcode.

## Hardware

Two Nvidia-equipped hosts, networked on the same LAN:

| Host | Role (default) | GPU | Compute | VRAM | Notes |
|------|----------------|-----|---------|------|-------|
| **hnvr-1** | Capture ingest (50% of cameras) + local analysis | GTX 1070 (Pascal) | 6.1 | 8 GB GDDR5 | CPU EP — cuDNN ≥ 9.12 dropped Pascal, so neither CUDA nor TensorRT EP is viable |
| **hnvr-2** (this node) | Capture ingest (50%) + local analysis + web + MediaMTX + NATS leader | RTX 4090 (Ada) | 8.9 | 24 GB GDDR6X | TensorRT 10 EP, full feature set |

**Inference plan**
- RTX 4090: YOLOv8n-320 via TensorRT EP → ~1 ms/frame; can do **YOLOv8s-640** at 100+ fps if accuracy demands.
- GTX 1070: YOLOv8n-320 via CPU EP (cuDNN ≥ 9.12 dropped Pascal) — slower per frame, so hnvr-1 carries fewer analysis cameras.
- CPU EP is the always-available fallback on any host.

## Key design decisions (locked)

| Decision | Choice | Why |
|----------|--------|-----|
| Deployment | **NixOS flake, multi-host, systemd** | Matches existing workflow; per-host NixOS config in same flake |
| Compiler | **GHC 9.12** (IHP experimental support) | Sergey's preference; bleeding edge — see "Risk" below |
| Language | **Haskell** | Single language across config/SQL/HTTP/CV |
| Web framework | **IHP pinned to release v1.6.0** (flake input `github:digitallyinduced/ihp/v1.6.0`) | Schema designer, autorefresh, auth, SSR |
| IPC | **NATS (core only; JetStream deferred)** | Lightweight; covers events/commands/health/config; clusterable post-v1 |
| CV runtime | **ONNX Runtime via internal Haskell FFI binding** (`hs-onnxruntime-capi` is too stale) | EP-agnostic: CPU / CUDA / TensorRT from one API |
| Stream ingestion | **ffmpeg subprocess, two independent RTSP pulls per camera** | Main stream `-c:v copy` to fMP4; sub-stream decoded for CV. Independent failure domains, ~50% LAN bandwidth saved vs decoding main twice |
| Recording container | **Fragmented MP4, 1-sec fragments → SeaweedFS (S3 API)** | HLS-ready; atomic upload; time-range queries |
| Live view | **MediaMTX v1.20 (RTSP → WebRTC WHEP)** | Pure-Haskell WebRTC is unrealistic; single Go binary |
| Storage | **SeaweedFS (S3) + PostgreSQL 18** *(external SaaS)* | Not our concern to operate |
| Object detection model | **YOLOv8n ONNX** at 320×320 default (per-camera override to YOLOv8s-640) | Mature ONNX export; class set: person + vehicles + cat/dog |
| Tracker | **SORT (Kalman + Hungarian) in pure Haskell** | ~250 LOC; deterministic; needed for line-crossing IDs |
| PTZ (v1) | **Manual PTZ + presets via ONVIF** | Industry-standard SOAP protocol; one driver covers most cameras. UI joystick + preset editor |
| Auto-track (v1.1) | **Closed-loop PID controller consuming tracker output, picks largest bbox** | Continues watching big territory by following the most prominent target. ~1–2 wks tuning per camera model |
| Scale model | **Two-host active/active capture, dynamic camera→host assignment via NATS** | Either host can die; web node rebalances |
| Topology | **Frames stay local per host; NATS carries only events/commands/health/config** | Avoids 675 KB/frame over the wire at 5 fps × 20 cams |

## GHC 9.12 risk register

| Risk | Mitigation |
|------|------------|
| IHP only "experimental" on 9.12 | Pin the `ihp` flake input to the v1.6.0 release tag; CI verifies `cabal build all` |
| `amazonka-s3` too heavy / capped for GHC 9.12 | Dropped amazonka entirely — storage lib is **minio-hs**, vendored at `vendored/minio-hs` with in-tree fixes (ListObjectsV2 continuation-token, deleteObject status validation) |
| `massiv`, `linear`, `cryptonite` upper bounds | Same `allow-newer` strategy; these packages are typically forward-compatible |
| `hs-onnxruntime-capi` won't build at all | Don't use it. Write internal ~150 LOC binding to ONNX Runtime C API |
| `IHPSchemaCompiler` quirks on PG 18 | IHP uses libpq; no PG-version coupling expected; smoke test in CI |

## Glossary

| Term | Meaning |
|------|---------|
| **Segment** | A 1-second fMP4 fragment stored in SeaweedFS; one row in `segments` table |
| **Event** | A row in `events` table — one CV detection with bbox, frame_ref, confidence |
| **Zone** | A polygon in normalized image coordinates defined per-camera |
| **Rule** | A line or zone with direction and class filter (e.g. "person crosses line A in +x direction") |
| **WHEP / WHIP** | WebRTC HTTP Egress / Ingestion Protocol — browser-friendly WebRTC signaling |
| **CaptureWorker** | A supervised `async` thread on a capture host that owns one RTSP→ffmpeg→S3 pipeline |
| **AnalyzerWorker** | A supervised `async` thread **co-located** with the CaptureWorker that taps the frame stream |
| **Leader** | The single web node that owns writes to Postgres `events` table + camera→host assignment |
| **Standby** | A second web node that takes over leadership via NATS KV lease (post-v1) |

## Topology at a glance

```
              ┌──────────────────────────────────────────────────┐
              │  External SaaS (out of project scope)             │
              │   ┌────────────┐         ┌─────────────────┐      │
              │   │ SeaweedFS  │         │  PostgreSQL 18  │      │
              │   │  (S3 API)  │         │                 │      │
              │   └─────▲──────┘         └────────▲────────┘      │
              └─────────┼─────────────────────────┼───────────────┘
                        │                          │
                        │   LAN (only one leg drawn) │
                        │                          │
   ┌────────────────────┼──────────────────────────┼──────────────────────┐
   │                    │                          │                       │
   │   hnvr-1 (GTX 1070)│                          │                       │
   │   ┌─────────────┐  │                          │                       │
   │   │ Capture×N   │──┘                          │                       │
   │   │ Analyzer×N  │─┐                           │                       │
   │   └─────────────┘ │                           │                       │
   │                   │ NATS                      │                       │
   │                   │ (core NATS)               │                       │
   │                   │  ▲  ▲  ▲                  │                       │
   │                   │  │  │  │                  │                       │
   │   ┌───────────────┘  │  │                  ┌──┴──────────────────┐    │
   │   │  events         │   commands         │  hnvr-2 (RTX 4090)   │    │
   │   │  health         │   config           │  ┌─────────────────┐ │    │
   │   └─────────────────┘                    │  │ Capture×N       │ │    │
   │                                          │  │ Analyzer×N      │ │    │
   │                                          │  ├─────────────────┤ │    │
   │                                          │  │ NATS (leader)   │ │    │
   │                                          │  │ IHP web (leader)│─┘    │
   │                                          │  │ MediaMTX        │      │
   │                                          │  └─────────────────┘      │
   │                                          └──────────────────────────┘    │
   │                                                                       │
   │   RTSP cameras ──── 192.168.0.x ────── both hosts pull directly        │
   └───────────────────────────────────────────────────────────────────────┘
                                       ▲
                                       │ HTTPS / WHEP
                                       │
                              ┌────────┴───────┐
                              │   Browser(s)   │
                              └────────────────┘
```

The next document (`01-architecture.md`) walks through each box, the NATS subjects, and the failure model in detail.
