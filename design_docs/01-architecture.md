# HNVR — Architecture

## Component map

```
hnvr/                                  one cabal project, multiple sublibs
├── hnvr-core         ── shared types, logging, telemetry, NATS bus, async-supervision
├── hnvr-nats         ── NATS connection pool, subject codecs (core NATS only — nats-queue has no JetStream)
├── hnvr-capture      ── RTSP supervision, ffmpeg subprocess mgmt, fMP4 segmenter, S3 put
├── hnvr-cv           ── ONNX runtime FFI, frame pre/post, tracker, line-crossing
├── hnvr-ptz          ── ONVIF PTZ client, driver abstraction, state machine
├── hnvr-storage      ── SeaweedFS client (vendored minio-hs), event publisher
└── hnvr-web          ── IHP app (live, archive, events, config UI, PTZ UI, leader logic)
```

Three executable targets:

| Binary | Where it runs | What it does |
|--------|---------------|--------------|
| `hnvr-node`  | Every host | CaptureWorker + AnalyzerWorker supervisor (one per assigned camera); pure worker, no HTTP |
| `hnvr-leader` | RTX 4090 host (one leader, standby possible) | All of `hnvr-node` + IHP web + MediaMTX config sync + EventWriter (drains NATS → Postgres); web publishes PTZ commands to `hnvr.commands.ptz.<slug>` directly (no separate coordinator component) |

Both binaries are executables of the `hnvr-web` cabal package (different `main` modules).

In v1, `hnvr-leader` is the only binary we ship on hnvr-2; `hnvr-node` runs on hnvr-1.

## Process model per host

```
Per host (systemd unit "hnvr-node.service" or "hnvr-leader.service"):
  RTS -N (cores), -A64m -I0
  └── NodeSupervisor
      ├── NATSConnection (one shared, multiplexed)
      ├── CaptureSupervisor
      │   ├── CaptureWorker "cam-196"   ── owns 1 ffmpeg record pipe + 1 ffmpeg analysis pipe
      │   ├── AnalyzerWorker "cam-196"  ── consumes in-process frame TChan from same CaptureWorker
      │   ├── CaptureWorker "cam-197"
      │   ├── AnalyzerWorker "cam-197"
      │   └── ...
      │   └── (csPtz) PtzController "cam-196" ── PTZ handles live inside CaptureSupervisor;
      │                                          one per PTZ-enabled camera; subscribes hnvr.commands.ptz.<cam>
      ├── HealthReporter              ── publishes hnvr.health.<host> every 5s
      └── ConfigWatcher               ── subscribes hnvr.config.> ; updates IORef (Map CameraId Camera)

Leader-only (in hnvr-leader.service):
      ├── WebServer (IHP / Warp)
      ├── EventWriter                 ── plain core-NATS subscriber on hnvr.events → Postgres
      ├── MediaMTXConfigSyncer        ── LISTENs on cameras_events (pg-simple) → pushes path config via MediaMTX /v3 REST API
      ├── RetentionSweeper            ── hourly, deletes old S3 segments + rows
      ├── AssignmentCoordinator       ── decides camera→host; publishes hnvr.commands.assign
      ├── PtzAuditWriter              ── consumes hnvr.ptz.audit → ptz_audit_log rows
      ├── PtzStatusCache              ── subscribes hnvr.ptz.status.<slug>, serves /PtzStatusCamera
      └── LeaderLease                 ── (post-v1, needs JetStream KV) standby promotes if lease expires
```

## Why frames stay in-process

A 640×360×3 RGB frame at 5 fps × 20 cams = 100 msgs/sec × 675 KB ≈ **67 MB/s** of payload. NATS *can* carry that (max payload configurable up to 64 MB / message), but it's a poor fit:

- Doubles latency (publish + network + subscribe queue).
- Wastes LAN bandwidth for the common case (both processes on same host).
- Demands NATS cluster throughput we don't otherwise need.

So: **each host runs CaptureWorker + AnalyzerWorker as a co-located pair**, frames go through an in-process bounded `TChan`. NATS carries only:

| Subject | Stream | Direction | Payload | Notes |
|---------|--------|-----------|---------|-------|
| `hnvr.events` | Core | AnalyzerWorker (any host) → EventWriter (leader) | `Event` JSON, ~500 B | Not durable — JetStream deferred; leader restart loses in-flight events |
| `hnvr.commands.assign.<cam>` | Core (ephemeral) | Leader → all nodes | `{camera_id, host}` | Reassign a camera to a host |
| `hnvr.commands.control.<host>.<cam>.<action>` | Core | Leader → host | `start\|stop\|restart` | Per-camera control |
| `hnvr.commands.ptz.<cam>` | Core (ephemeral) | Web UI (leader) → host owning camera | `{command, args, source}` | PTZ op: continuous_move / stop / goto_preset / set_preset / remove_preset |
| `hnvr.health.<host>` | Core (max-age 15s) | Node → all | `{host, cameras:[{slug,state}], cpu_pct, gpu_model, exec_providers, gpu_mem_bytes, ram_bytes}` | Leader uses for status page; standby uses for failover |
| `hnvr.config.cameras.<slug>` | Core | Leader → all | full `Camera` JSON | Broadcast on row change |
| `hnvr.ptz.status.<cam>` | Core (max-age 2s) | Host owning cam → all | `{state, position, last_command_at}` | Live UI reads for PTZ indicator |
| `hnvr.leader` | (post-v1) JetStream KV, TTL 10s | Leader → all | `leader_id, since` | Lease; standby promotes on expiry — needs JetStream, deferred |

Also on the bus: `hnvr.ptz.audit` (node → leader `PtzAuditWriter`; one record per executed PTZ command, with ok/error) and `ClipReady` messages on `hnvr.events` (event clips, v0.4.0.0).

## Per-camera data flow (co-located capture + analyze)

Two **independent** RTSP pulls per camera — one to the main stream (recording, `-c:v copy`), one to the sub-stream (analysis, decoded). They are independent failure domains: sub-stream going down doesn't drop a single recorded frame; main stream going down pauses recording but analyzer keeps working on the sub-stream until it also fails.

```
                              ┌──── RTSP main stream ────
                              │     (e.g. 4K HEVC @ 25fps)
                              ▼
                       ┌──────────────────────────────────┐
                       │ ffmpeg -rtsp_transport tcp       │
                       │   -i rtsp_url                    │  ◀── recording path: NO re-encode
                       │   -c:v copy -f mp4 ...           │      (split into 1s fMP4 fragments)
                       │   -movflags frag_keyframe+empty │
                       │        moov+default_base_moof   │
                       │   pipe:1                        │
                       └──────────────┬───────────────────┘
                                      │ fMP4 bytes
                                      ▼
                              ┌─────────────┐
                              │ Segmenter   │   → SeaweedFS put
                              │ 1s chunks   │   → NATS "hnvr.events"
                              └─────────────┘


   ┌──── RTSP sub-stream ─────┐
   │    (e.g. 640×480 H.264   │
   │     @ 10 fps, ~256 kbps) │
   └────────────┬─────────────┘
                ▼
       ┌─────────────────────────────────────────┐
       │ ffmpeg -rtsp_transport tcp              │
       │   -i rtsp_sub_url                       │  ◀── analysis path: small decode only
       │   -an                                   │      (no -vf scale: sub already small)
       │   -pix_fmt rgb24 -f rawvideo            │
       │   -r 5 pipe:1                           │
       └──────────────┬──────────────────────────┘
                      │ raw RGB frames (in-process, bounded TChan capacity 4, drop-oldest)
                      ▼
              ┌──────────────────────────────────────────┐
              │ AnalyzerWorker (same OS process)         │
              │   preproc (letterbox to 320×320)         │
              │   → ONNX → NMS → SORT → rules            │
              │   → publish "hnvr.events"                │
              └──────────────────────────────────────────┘
```

**Fallback**: if `use_substream_for_analysis=true` but `rtsp_sub_url` is `NULL` or the sub-stream repeatedly fails, the analyzer ffmpeg transparently falls back to `rtsp_url` with `-vf scale=W:H` (degraded CPU cost, recording unaffected). State machine tracks this — see `03-capture-and-storage.md`.

**Why sub-stream (not main-stream-decode)**
- 4K HEVC software decode is ~30–50% of one core per camera. Sub-stream decode (typically 640×480 H.264) is ~3–5%.
- Cuts ~50% LAN bandwidth (we no longer pull 4K twice).
- Camera hardware encodes the sub-stream essentially for free.
- Analysis works in normalized coords (0..1) — bboxes from sub-stream overlay perfectly on main-stream recording when scaled for display.

The recording path uses `-c:v copy` (zero CPU). The analysis path pulls the small sub-stream (cheap decode). Three ffmpeg processes per camera max (record + analyze + optional audio), but each is small.

**Segment-row insert path**: the CaptureWorker doesn't write `segments` rows directly to Postgres. It publishes a `SegmentWritten` event on the `hnvr.events` subject (same core-NATS subject as CV events, but a different `kind`). The leader's `EventWriter` consumes and inserts. This keeps all Postgres writes on the leader, simplifying the SaaS PG topology. Workers need only NATS + S3 credentials.

## Leader election

Single leader in v1 (the RTX 4090 host). Standby promotion is a post-v1 item — it needs JetStream KV, which is deferred (nats-queue has no JetStream):

1. Leader writes `hnvr.leader` KV bucket entry every 5 s with TTL 10 s.
2. Standby (if running) watches the bucket. If entry expires, standby writes its own entry, becomes leader, starts `EventWriter`, `MediaMTXConfigSyncer`, `WebServer`.
3. Old leader, when it recovers, sees someone else owns the lease and goes into standby.

This is textbook NATS KV-based leader election. ~30 LOC in `Hnvr.Leader`.

## Camera→host assignment

`AssignmentCoordinator` (leader-only) maintains `Map CameraId HostId`:

- Default: hash partition cameras across all hosts reporting healthy via `hnvr.health.<host>`.
- On host-down detection (no health in 15 s): redistribute that host's cameras to the other healthy host, publish `hnvr.commands.assign.<cam>` for each moved camera.
- On host-up: optionally rebalance (configurable; off by default to avoid flapping).

Each host's `CaptureSupervisor` listens on `hnvr.commands.assign.>` and starts/stops the corresponding worker pair.

## PTZ control path

Each host that owns PTZ-enabled cameras runs one `PtzController` (async thread) per camera. The leader's web UI never talks SOAP to the camera directly — it publishes on `hnvr.commands.ptz.<cam>` and the host owning the camera executes.

```
browser (PTZ joystick / preset button)
   │ POST /PtzCamera?ptzCameraId=<uuid> { command, args }   (fire-and-forget)
   ▼
IHP action (leader)
   │ auth check (admin OR cameras.ptz_viewer_control=true)
   │ publish hnvr.commands.ptz.<slug> { command, args, source: 'web_ui', user_id }
   ▼
PtzController on host owning <cam> (a CaptureSupervisor csPtz handle)
   │ resolved-endpoint record of Either-returning IO ops
   │ (Hnvr.Ptz.Onvif.OnvifPtz — the design's PtzDriver typeclass was dropped)
   │ SOAP request to camera's ONVIF PTZ endpoint (runtime discovery)
   │ publish audit record on hnvr.ptz.audit (ok/error)
   │ publish hnvr.ptz.status.<slug> { state, last_command_at }
   ▼
Camera mechanical response
```

Nodes have no database access, so audit rows are not inserted node-side: the
leader's `PtzAuditWriter` subscribes `hnvr.ptz.audit` and persists each record
to `ptz_audit_log` (with `ok`/`error` columns — execution, not publish intent).

**State machine per PTZ-enabled camera** (lives in `PtzController`'s `MVar`, broadcast on `hnvr.ptz.status.<cam>` at every transition):

```
                 ┌──────────┐
       ┌────────▶│   Idle   │◀───── on boot, on Stop, on goto_preset complete
       │         └────┬─────┘
       │              │ continuous_move from UI
       │              ▼
       │         ┌──────────────┐
       │         │ ManualMove   │  ── ContinuousMove every 200ms while joystick held
       │         └────┬─────────┘
       │              │ Stop or joystick release
       │              ▼
       │         ┌──────────────┐
       │         │ ReturningHome│  ── if ptz_idle_timeout_s > 0 and idle since > timeout
       │         └────┬─────────┘
       │              │ home preset reached
       └──────────────┘
       (any state)
              │ goto_preset from UI
              ▼
         ┌──────────────┐
         │ GoingToPreset│  ── AbsoluteMove + poll GetStatus until reached
         └────┬─────────┘
              │ reached
              ▼
            Idle

   v1.1 addition:
         ┌──────────────┐
         │ AutoTracking │  ── AutoTrack consumer emits ContinuousMove from CV output
         └────┬─────────┘
              │ operator joystick / preset / lost target for >N sec
              ▼
            Idle (or ReturningHome)
```

Manual input **always preempts** auto-track (v1.1). This is enforced by the PtzController: any `web_ui` command sets state to `ManualMove` and clears any `AutoTracking` flag.

**Auto-track** (v1.1, design in `04-cv-pipeline.md`): separate consumer of tracker output runs inside the AnalyzerWorker. When enabled, it picks the largest matching bbox, computes a velocity command via PID, and publishes on `hnvr.commands.ptz.<cam>` with `source: 'auto_track'`. Same path as manual, just a different source.

## Live view path (leader only)

```
browser <video>
   │ WebRTC WHEP GET
   ▼
MediaMTX ─── pulls RTSP from camera on demand ───▶ camera
   ▲
   │ path config pushed via the MediaMTX /v3 REST API by MediaMTXConfigSyncer
   │ (pg-simple LISTEN on cameras_events) whenever a camera row changes
```

MediaMTX runs **on the leader host only** (RTX 4090 box). It connects to cameras directly over the LAN — the fact that the camera's recorder pipeline runs on a different host is irrelevant; MediaMTX just needs the RTSP URL.

**Cross-host live optimization (post-v1)**: run MediaMTX on each capture host, route WHEP requests to the host already pulling the camera. Skipped in v1 to keep one MediaMTX config in one place.

## Archive playback path (leader only)

```
browser ─── GET /archive/<cam>/playlist.m3u8?from=...&to=
   │
   ▼
IHP action (leader)
   │  query segments table for [from, to]
   │  build a synthetic HLS playlist pointing at SeaweedFS presigned URLs
   │  (each 1-sec fMP4 segment becomes one HLS #EXTINF:1.0 entry)
   ▼
browser <video> ─── fetches each .mp4 with presigned URL ───▶ SeaweedFS
```

No transcoding. The fMP4 fragments are already HLS-compatible. The `m3u8` is generated per request; 1-hour window = 3600 lines, fine.

## Failure modes and guarantees

| Failure | Consequence | Mitigation |
|---------|-------------|------------|
| Camera reboots | Both ffmpeg exit, capture worker restarts in 2 s, gap of one segment recorded | `recording_gaps` event |
| **Sub-stream down, main stream alive** | Recording continues. Analyzer ffmpeg retries sub-stream 3×, then **falls back to main stream with `-vf scale`** (degraded CPU). Alert logged. | `hnvr_substream_fallback_total{cam}` metric |
| **Main stream down, sub-stream alive** | Recording pauses (gap). Analyzer keeps running on sub-stream. CaptureWorker retries main. | `recording_gaps` event |
| Network glitch to camera | Both ffmpegs exit, worker restarts with backoff | Capped exponential backoff, 30 s max |
| **hnvr-1 host dies** | Its cameras reassigned to hnvr-2 within 15 s via NATS commands | `AssignmentCoordinator` watches health bus |
| **hnvr-2 (leader) dies** | Standby (if running) takes over in 10 s; otherwise v1 = manual restart | Single point of failure in v1 — accepted, fix in post-v1 |
| NATS node dies | No events flow; capture continues writing to S3; analyzer events buffer in worker memory (max 1000) then drop | Counter `hnvr_events_dropped_total`; deploy NATS with replication post-v1 |
| SeaweedFS brief unreachability | 60 s spool buffer to local disk, then drop-newest | Metric `hnvr_segments_dropped_total` |
| Postgres brief unreachability | EventWriter buffers in memory; analyzer workers don't notice (events are fire-and-forget on core NATS) | Worker-side buffer (max 1000), then drop with counter |
| ONNX model throws | Analyzer worker dies, restarted, recorder unaffected | Supervisor restart with 5/60s budget |
| Disk full (spool) | Capture worker pauses writing, retries | Alerts; manual intervention |
| Whole host reboot | systemd brings up hnvr-node (or hnvr-leader) + mediamtx (leader) + nats in order | `Requires=` + `After=` in unit |

## Telemetry

Prometheus metrics are served by a separate warp listener on `HNVR_METRICS_PORT` (default `9100`; devenv uses `9102`) per host — NOT an IHP endpoint. Metrics (per-camera + per-host labels):

- `hnvr_frames_decoded_total{host,cam}`
- `hnvr_frames_dropped_total{host,cam}`
- `hnvr_segments_written_total{host,cam}` and `_bytes`
- `hnvr_inference_seconds{host,cam,model,ep}` histogram
- `hnvr_events_emitted_total{host,cam,rule}`
- `hnvr_events_dropped_total{host}` — failed NATS publish
- `hnvr_ffmpeg_restarts_total{host,cam}`
- `hnvr_s3_put_seconds{host}` histogram
- `hnvr_nats_publish_seconds{host,subject}` histogram
- `hnvr_gpu_memory_used_bytes{host,gpu}`
- `hnvr_camera_assignment{host,cam}` gauge (0 or 1)

Logging is structured (`fast-logger`), one file per worker under `/var/log/hnvr/`, rotated by logrotate (NixOS module).
