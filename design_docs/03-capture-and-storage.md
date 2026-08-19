# HNVR — Capture & Storage

This document covers everything between the camera's RTSP port and SeaweedFS/Postgres. CV analysis is in `04-cv-pipeline.md`; NATS plumbing in `01-architecture.md`.

## Per-camera capture pipeline

**Two independent RTSP pulls per camera**, supervised by one `CaptureWorker` (Haskell `async`):

1. **Main stream** → recording ffmpeg with `-c:v copy` (zero CPU)
2. **Sub-stream** → analysis ffmpeg with decode only (small, cheap)

A third optional ffmpeg handles muxed audio from the main stream when `record_audio=true`. The CaptureWorker and its co-located AnalyzerWorker run **on the same host** (frames never cross the wire).

### 1. Recording ffmpeg (main stream, zero-CPU `-c:v copy`)

```
ffmpeg -hide_banner -loglevel warning \
  -rtsp_transport tcp \
  -i '<rtsp_url>' \
  -user_agent 'HNVR/0.1' \
  -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
  -an \
  -c:v copy \
  -f mp4 \
  -movflags +frag_keyframe+empty_moov+default_base_moof+omit_tfhd_offset+faststart \
  -frag_duration 1000000 \
  -reset_timestamps 1 \
  pipe:1
```

Key flags:

- `-rtsp_transport tcp` — TCP interleaved; no UDP packet loss on local LAN.
- `-reconnect*` — ffmpeg-level reconnect on RTSP drop, max 5 s backoff. Belt-and-braces; the Haskell worker also supervises.
- `-an` on recorder by default — drop audio for the CV path; muxed audio goes into a **third** ffmpeg if `record_audio=true`.
- `-c:v copy` — no decode, no encode. Cost is just demux/remux.
- `-movflags +frag_keyframe+empty_moov+default_base_moof+omit_tfhd_offset` — produces HLS-ready fMP4 fragments directly off the demuxer.
- `-frag_duration 1000000` — request 1-second fragments. ffmpeg honors this approximately (one per keyframe).
- `-reset_timestamps 1` + `omit_tfhd_offset` — fragments are independent and HLS-compatible.
- `pipe:1` — emit bytes on stdout.

We read stdout with a fixed 64 KiB buffer and accumulate into a `Data.ByteString.Builder`. A small (~80 LOC) fMP4 parser in `Hnvr.Capture.Fmp4` watches `moof`/`tfdt` boundaries and yields fragments at the 1 s mark.

### 2a. Analysis ffmpeg — sub-stream (default)

When `use_substream_for_analysis=true` **and** `rtsp_sub_url` is set:

```
ffmpeg -hide_banner -loglevel warning \
  -rtsp_transport tcp \
  -i '<rtsp_sub_url>' \
  -user_agent 'HNVR/0.1' \
  -rtsp_flags prefer_tcp \
  -an \
  -pix_fmt rgb24 \
  -r 5 \
  -f rawvideo \
  pipe:1
```

No `-vf scale` filter — the sub-stream is **already small** (typically 640×480 / 704×480 / 704×576 H.264 from the camera). We just decode to RGB24 and pipe. ffmpeg tells us the actual width/height in its stderr probe output; the CaptureWorker parses it once at startup and stamps every emitted `Frame` with the correct dims.

Decode cost: ~3–5% of one core per camera (vs ~30–50% for 4K HEVC main-stream decode).

### 2b. Analysis ffmpeg — fallback (main stream with `-vf scale`)

Used when `use_substream_for_analysis=false` **OR** the sub-stream has failed 3 consecutive restarts (auto-fallback):

```
ffmpeg -hide_banner -loglevel warning \
  -rtsp_transport tcp \
  -i '<rtsp_url>' \
  -user_agent 'HNVR/0.1' \
  -an \
  -vf 'scale=640:360:force_original_aspect_ratio=decrease,pad=640:360:(ow-iw)/2:(oh-ih)/2' \
  -pix_fmt rgb24 \
  -r 5 \
  -f rawvideo \
  pipe:1
```

Same shape as the v0 design. Used as safety net; alarm via `hnvr_substream_fallback_total{cam}` counter so ops know CPU is being burned.

**Auto-fallback state machine** (per camera):
- 3 consecutive sub-stream ffmpeg exits within 60 s → switch to main-stream-with-scale for analysis
- Every 5 min, attempt to revert to sub-stream
- If sub-stream succeeds for 60 s, mark recovered; stop alarm

### 3. Audio ffmpeg (only if `record_audio=true`)

Per-camera `record_audio` defaults to `false`. If enabled, a third ffmpeg pulls the main stream:

```
ffmpeg ... -i '<rtsp_url>' -vn -c:a copy -f mp4 \
  -movflags +frag_keyframe+empty_moov+default_base_moof+omit_tfhd_offset \
  -frag_duration 1000000 pipe:1
```

Audio fragments written as `cam-196/.../<ts>.m4a` referenced from the same segment row.

## Why two (or three) independent RTSP pulls

Each ffmpeg connects to the camera independently. Failure isolation is excellent:

- Sub-stream down → recording unaffected (main ffmpeg still going).
- Main stream down → analyzer keeps running on sub-stream; recording pauses only.
- Audio ffmpeg down → video recording unaffected.

Trade-off: two concurrent RTSP sessions per camera (three if audio). Most consumer IPCs cap concurrent sessions at ~4; with 2 per camera we have headroom for a browser preview session via MediaMTX. Watch the limit during host failover when one host temporarily pulls both its own + the failed host's cameras (4 sessions per camera briefly).

**Total cost** at 10 cameras per host with sub-stream analysis: ~3% CPU per camera for record (RTSP demux + fMP4 mux), ~4% per camera for sub-stream analysis decode = ~70% of one core total for capture. **Half** what the main-stream-decode design cost.

## Supervision: the `CaptureWorker` state machine

```
                 ┌──────────────────┐
                 │     Pending      │  ─── CaptureSupervisor spawns worker
                 └────┬─────────────┘
                      │ start ffmpeg pairs, open NATS pub, prime spool dir
                      ▼
              ┌───────────────────┐
       ┌──────│      Running      │──────┐
       │      └───────────────────┘      │
       │ ffmpeg exit / 5x failure       │ hnvr.commands.assign to other host
       ▼                                 ▼
   ┌───────────┐                  ┌────────────┐
   │ Backoff   │ ── 2,4,8,16,30s ─│  Stopped   │
   └─────┬─────┘                  └────────────┘
         │ retry
         └────────▶ Running
   5 failures / 60s
         ▼
   FailedPermanent ── retry every 5 min ──▶ Running
```

State lives in an `MVar CaptureState`; transitions emit `hnvr_ffmpeg_restarts_total{host,cam}`. After 5 failures within 60 s → `FailedPermanent`, alert logged; worker stays alive and retries every 5 min.

**Cross-host takeover**: when leader publishes `hnvr.commands.assign.<cam>` to a new host, the old host's supervisor stops the worker cleanly (`Stopped`), the new host's supervisor starts it. The camera's segments continue uninterrupted (the new ffmpeg reconnects within ~2 s — gap of one segment).

## Fragment → SeaweedFS write protocol

```haskell
data Segment = Segment
  { sCamera  :: CameraId
  , sStart   :: UTCTime
  , sEnd     :: UTCTime
  , sBytes   :: ByteString    -- fMP4 fragment
  , sSha     :: Sha256
  , sKind    :: Video | Audio
  , sHostId  :: HostId        -- which host captured this segment
  }
```

1. Segmenter closes a fragment at wall-clock second boundary.
2. Compute `sSha = sha256 sBytes`.
3. Object key: `cam-196/2026-08-07/14-30-15.mp4` (UTC, `%Y-%m-%d/%H-%M-%S`).
4. `PutObject` to the external SeaweedFS (`http://192.168.0.254:8333`), single bucket `hnvr`, headers:
   - `Content-Type: video/mp4`
   - `x-amz-meta-sha256: <hex>`
   - `x-amz-meta-camera-id: cam-196`
   - `x-amz-meta-host-id: hnvr-1`
5. On 200 OK, publish a `SegmentWritten` event to NATS subject `hnvr.events` (core NATS — JetStream deferred). Leader's `EventWriter` consumes and inserts the `segments` row.

**Why publish via NATS instead of direct Postgres insert?** All Postgres writes happen on the leader (single SaaS connection string, single writer simplifies the IHP schema sync). Workers don't need DB credentials at all — only NATS + S3 credentials.

**Spool on S3 outage**: local disk under `/var/lib/hnvr/spool/<host>/cam-196/<ts>.mp4`, capacity 60 s. A separate `SpoolDrainer` thread re-uploads when S3 returns. Past 60 s, drop-newest and bump counter.

## SeaweedFS bucket layout

Everything lives in a **single bucket `hnvr`** on the external SeaweedFS
(`http://192.168.0.254:8333`) — recordings, event thumbnails, and event clips
(the originally-planned `hnvr-recordings` / `hnvr-events` / `hnvr-exports`
split never shipped):

```
hnvr/                                           -- the only bucket
  cam-196/
    2026-08-07/
      14-30-15.mp4                              -- recording segments
      14-30-15-track-42.png                     -- event thumbnails/crops
      ...
    clips/
      2026-08-07/14-30-15.123/                  -- event clips (v0.4.0.0)
        init.mp4
        14-30-15.123.mp4
        ...
  cam-197/...
  cam-198/...
```

Retention is per-camera (`cameras.retention_hours`) and per-clip
(`event_clips.retention_hours`, snapshotted from the rule at creation).

## PostgreSQL indexes (on the external PG 18)

Defined in `Application/Schema.sql` (IHP) — see `06-data-model.md`. Capture-relevant:

```sql
CREATE INDEX segments_cam_start_idx
  ON segments (camera_id, start_ts DESC);
CREATE INDEX segments_start_ts_brin
  ON segments USING brin (start_ts);
```

BRIN on `start_ts` is critical: 20 rows/cam/min ≈ 17 M rows/year/cam. BRIN on a naturally time-ordered insert is essentially free.

## Retention sweep (leader-only)

`RetentionSweeper` runs every hour on the leader:

1. Per-camera cutoff from `cameras.retention_hours` (default 168 h; the
   `retention_policies` table idea was dropped — retention is hours-based,
   `INTERVAL '1 hour'` arithmetic).
2. List SeaweedFS objects under `cam-X/` older than cutoff via `ListObjectsV2` (paginated, 1000 at a time).
3. Batch `DeleteObjects` (max 1000 per request).
4. `DELETE FROM segments WHERE camera_id=$1 AND end_ts < $2` in 10 000-row chunks until `row_count = 0`.

It also sweeps expired `event_clips` (prefix-scoped exact delete) and stale
tombstones (90 s grace). Tombstoned rows (`pending_delete_at`) are skipped by
the retention path — they belong to the purge worker.

Idempotent — safe to kill mid-run. SeaweedFS deletion happens first; if the sweeper dies after delete but before PG delete, the next run completes the cleanup.

## Event clips (shipped, v0.4.0.0)

Rules with `clip_retention_hours` set produce event video clips: a per-camera
ring buffer (`Hnvr.Capture.RingBuffer`) snapshots the main fragment stream at
rule fire (`[ts - clip_preroll_sec, ts]`), `Hnvr.Node.ClipRecorder` extends one
open clip per camera on subsequent fires, and a 1 s ticker closes + uploads
`init.mp4` + fragments under `<slug>/clips/<YYYY-MM-DD/HH-MM-SS.mmm>/`.
Playback via `/PlayerEventClip` + `/PlaylistEventClip`; the old `export_jobs`
clip-export design never shipped — event clips replaced it.

## Tombstone deletion (shipped, v0.3.0.0)

User-initiated recording deletion is two-phase: `PurgeRecordingAction` stamps
`segments.pending_delete_at` synchronously (all read paths filter it out), then
an async purge worker deletes the S3 objects, re-lists the window, and hard-
DELETEs the rows only once verified empty. A 60 s sweeper (90 s grace) resumes
batches whose worker died. `event_clips` gained the same tombstone column in
0007.

## Throughput budget (worst case, 20 cameras split 10/10 across hosts)

- Main stream 4K HEVC @ 25fps ≈ 4 Mbps ≈ 500 KB/s per camera → 1 segment/sec ≈ 500 KB.
- Sub-stream 640×480 H.264 @ 10fps ≈ 256 kbps ≈ 32 KB/s per camera (we pull `-r 5` of those for analysis).
- Per host: 10 cams × 1 main-stream put/sec = 10 puts/sec, ~5 MB/s write bandwidth to SeaweedFS.
- Total SeaweedFS: 20 puts/sec, ~10 MB/s write — trivial for any S3-compatible storage.
- Postgres inserts (on leader): 20 segments/sec + ~5 events/sec = trivial.

LAN bandwidth per camera: ~530 KB/s (main + sub) vs the previous ~1 MB/s (main pulled twice). **~50% reduction**.

Disk budget for segments: 20 cams × 500 KB/s × 86400 s ≈ **~860 GB/day, ~6 TB/week, ~26 TB/month** in SeaweedFS. **Plan ≥ 8 TB usable for 7-day retention.** Capacity is the SaaS owner's concern; we surface usage via dashboard.

## Per-camera config that drives this

```sql
cameras (
  id              UUID PRIMARY KEY,
  slug            TEXT UNIQUE NOT NULL,         -- 'cam-196'
  name            TEXT NOT NULL,
  -- main stream (authoritative for recording)
  rtsp_url        TEXT NOT NULL,                -- full URL with creds
  -- rtsp_template / port dropped in v0.5.2.0 (migration 0010): templates
  -- never had form inputs; port had no logic consumer.
  host            INET,
  username        TEXT,
  password        TEXT,                         -- stored encrypted
  codec           TEXT,                         -- 'hevc' / 'h264' (informational)
  -- sub-stream (authoritative for analysis)
  rtsp_sub_url    TEXT,                         -- NULL = main with -vf scale
  use_substream_for_analysis BOOL DEFAULT TRUE,
  substream_codec TEXT DEFAULT 'h264',
  substream_width INT,                          -- informational, probed at startup
  substream_height INT,
  -- capture
  record_audio    BOOL DEFAULT false,
  analysis_fps    INT DEFAULT 5,
  -- lifecycle
  enabled         BOOL DEFAULT true,
  retention_hours INT DEFAULT 168,
  -- assignment (managed by leader's AssignmentCoordinator)
  assigned_host   TEXT                          -- 'hnvr-1' | 'hnvr-2' | NULL
)
```

`rtsp_url` is the source of truth for the recording path (the `rtsp_template` rendering idea was dropped in v0.5.2.0 — workers never build URLs).

**Sub-stream URL discovery (manual in v1, ONVIF in post-v1)**:
- Probe with `ffprobe 'rtsp://...?stream=SubStream'` and `stream=1` to find the working scheme.
- Common patterns by camera vendor:
  - icamra (`stream=MainStream`): try `stream=SubStream`
  - Generic numbered (`stream=0`): try `stream=1`
  - Hikvision: `/Streaming/Channels/102` (sub) vs `/101` (main)
  - Dahua: `/cam/realmonitor?channel=1&subtype=1`

Passwords are encrypted at rest with AES-256-GCM using a key from `sops-nix` (see `07-deployment.md`). CaptureWorkers decrypt on read.

## `assigned_host` lifecycle

1. Admin creates/edits camera via web UI → IHP writes row.
2. Trigger publishes `hnvr.config.cameras.<slug>` with the new row.
3. Leader's `AssignmentCoordinator` sees the change, picks a host (default: least-loaded healthy host), updates `cameras.assigned_host`, republishes.
4. Leader publishes `hnvr.commands.assign.<cam>` → `hnvr-1` (or `hnvr-2`).
5. Target host's CaptureSupervisor spawns CaptureWorker + AnalyzerWorker.
6. Old host (if reassigning) gets `hnvr.commands.control.<old_host>.<cam>.stop`, drains gracefully.

Manual override: admin sets `assigned_host` directly in UI; coordinator respects.
