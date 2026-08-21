# HNVR — Unified Archive Timeline

Status: **shipped (Aug 20 2026, v0.14.0.0)** — all three phases landed.
`/Timeline` is the archive UI (sidebar "Archive"); the old recordings
table is gone. `/PlayerArchive` + `/PlaylistArchive` remain for
single-camera deep links and per-tile playback.

## Problem

The current archive UX is per-camera and table-driven: pick a camera, pick a
window, open a single-camera HLS player. Investigating an incident means
manually correlating times across N cameras. `/Events` deep-links into the
single-camera player but gives no cross-camera context.

## Goals

1. **One timeline for all cameras.** A single horizontal slider spanning a
   time range (default: **last 24 h**) rendered with:
   - per-camera **coverage bars** (merged recorded spans from `segments`),
   - **event markers** from *all* cameras placed at their exact `events.ts`.
2. **Draggable cursor.** Mouse-drag the cursor to seek; while dragging, every
   enabled camera tile live-updates a thumbnail at (nearest ≤) the cursor time.
3. **Sync playback on release.** On `pointerup`, every enabled camera with
   coverage at the cursor starts archive playback from that exact time.
4. **Per-camera enable toggle** to exclude a camera from thumbnails/playback.
5. Thumbnails at *arbitrary* times require a new **periodic snapshot store**
   (decision recorded below).

Non-goals (v1): export/clip assembly from the timeline, motion-heatmap,
>20 cameras layout optimisation, touch gestures.

## Decisions (locked with Sergey)

| Question | Decision |
|---|---|
| Thumbnail source | **Periodic snapshot store** — new pipeline writes a JPEG per camera every `snapshot_interval_sec` to S3 + `camera_snapshots` table |
| Page structure | New timeline page **replaces `/Archive`** as the archive UI; the existing single-camera `/PlayerArchive` + `/PlaylistArchive` stay for deep links (`/Events` rows, audit) |
| Cursor in a gap | Tile shows thumbnail **only where coverage exists**; elsewhere a gap/no-recording placeholder. No snap-to-nearest. |

## Page: `/Timeline` (becomes the sidebar "Archive" entry)

```
┌──────────────────────────────────────────────────────────────┐
│ Range: [1h] [6h] [24h*] [custom from/to]   t cursor label    │
├──────────────┬──────────────┬──────────────┬────────────────┤
│ ▣ backyard   │ ▣ floor_2_5  │ ▣ low_ent    │  … tiles       │
│ [thumbnail]  │ [thumbnail]  │ [no record]  │  (grid, wraps) │
│ ☐ disabled   │ playing ▶    │ —            │                │
├──────────────┴──────────────┴──────────────┴────────────────┤
│ timeline canvas:                                             │
│   backyard   ███████░░░█████████████░░░████  ← coverage      │
│   floor_2_5  ██████████████████████████████                  │
│   low_ent    ░░░░░░░██████████░░░░░░░░░░░░                   │
│   events      ▲   ▲ ▲      ▲ (colored per camera, stacked)   │
│   ──────────────────────│──────────────────  ← cursor (drag) │
└──────────────────────────────────────────────────────────────┘
```

### Layout

- **Top bar**: range presets `1h / 6h / 24h` (24h default) + custom
  `datetime-local` from/to (existing `input[data-tz-dt]` local↔UTC JS
  pattern, MEMORIES v0.12.0.0). Changing the range re-fetches timeline data
  and keeps the cursor if still in-window.
- **Camera grid**: one tile per camera (all cameras, not just recording
  ones — disabled cameras render greyed with their toggle pre-off).
  - tile head: slug + enable checkbox (persisted in
    `localStorage["hnvr-timeline-disabled"]` as a JSON array of camera uuids),
  - tile body: `<img>` thumbnail during scrub, `<video>` (hls.js) after
    release, or a `NO RECORDING` placeholder when the cursor sits in a gap,
  - tile footer: state line (`idle` / `seeking…` / `playing` / `gap`).
- **Timeline** (canvas, ~120 px tall): one coverage lane per camera (ordered
  by slug, matching the grid), one shared event-marker lane, cursor line with
  a grab handle. Cursor label shows the time via the existing
  `HNVR.viewerTz()` / `Intl.DateTimeFormat("sv-SE", …)` machinery.

### Interaction state machine

```
idle ──pointerdown on handle──▶ scrubbing ──pointermove──▶ scrubbing
                                   │ (per move: update cursor + fetch thumbs,
                                   │  debounced 150 ms per camera)
                                   ▼ pointerup
                             loading playlists ──▶ playing
```

- **Scrubbing**: cursor position → UTC time `t`. For each *enabled* camera
  with coverage at `t`, the tile swaps to `<img src=/TimelineThumb?cameraId=…&t=…>`.
  Debounce per camera; in-flight fetches are aborted on the next move
  (`AbortController`).
- **Release**: for each enabled camera:
  - coverage at `t` → build `/PlaylistArchive?cameraId=…&from=t&to=rangeEnd`
    (existing 6 h cap applies; `to = min(rangeEnd, t+6h)`), attach hls.js,
    `startPosition = offset of t inside first segment`, play muted.
  - no coverage → `NO RECORDING` placeholder, no player created.
- **Post-release scrub**: dragging again tears down players (hls.js
  `destroy()`) and returns tiles to thumbnail mode.
- **Event markers**: click a marker → cursor jumps to `events.ts` and the
  tile set seeks (same as a release at that time). Marker tooltip: camera
  slug, kind, rule name, localized time. Shift-click opens the event clip
  player (`/PlayerEventClip`) when one exists.
- **Deep-linkable**: `?from=&to=&t=&cams=<csv of disabled uuids>` — the
  `/Events` table's "▶" links are repointed here (row camera enabled, all
  others left as the user's toggle state).

### Zoom/pan of the timeline itself

v1: range presets + custom from/to only. Wheel-zoom-around-cursor and
background-drag panning are stretch goals; the data API is windowed already,
so they are pure-JS additions later.

## Server side

### New JSON/data endpoints (new `Web.Controller.Timeline`, `ensureIsUser`)

| Method | Path | Purpose |
|---|---|---|
| GET | `/Timeline` | HTML page shell (cameras, initial window) |
| GET | `/TimelineData?from=&to=` | JSON: per-camera coverage spans + event markers |
| GET | `/TimelineThumb?cameraId=&t=` | 302 → presigned S3 URL of nearest `camera_snapshots` row with `ts ≤ t` (404 when none within `snapshot_interval_sec × 4`) |

`TimelineData` response (cap: 500 markers/camera, bucketed by time when over):

```json
{
  "from": "…", "to": "…",
  "cameras": [{
    "id": "uuid", "slug": "backyard",
    "spans": [{"start": "…", "end": "…"}],
    "events": [{"id": "…", "ts": "…", "kind": "zone_motion",
                "rule": "perimeter", "clipId": "…|null"}]
  }]
}
```

- Coverage: `segments` rows in window, `pending_delete_at IS NULL`,
  merged with the existing `Hnvr.Core.Recording.groupRecordings` /
  `splitTolerance = 30 s` logic — pure, already tested.
- Markers: `events` in window across all cameras (`events_ts_brin` +
  per-cam `events_cam_ts_idx` cover it), with the clip-id scalar subquery
  copied from `fetchEventRows`.
- Both endpoints reuse `parseWhen` for `from`/`to` (UTC ISO or
  `datetime-local`, same as today).

### Snapshot store (new pipeline)

**Schema (migration 0013-camera-snapshots):**

```sql
CREATE TABLE camera_snapshots (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id   UUID NOT NULL,
    ts          TIMESTAMP WITH TIME ZONE NOT NULL,
    object_key  TEXT NOT NULL,
    bytes       BIGINT NOT NULL,
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    FOREIGN KEY (camera_id) REFERENCES cameras(id) ON DELETE CASCADE
);
CREATE INDEX camera_snapshots_cam_ts_idx
    ON camera_snapshots (camera_id, ts DESC);

ALTER TABLE cameras
    ADD COLUMN snapshot_interval_sec INT NOT NULL DEFAULT 60;
```

- Object key: `<slug>/snapshots/<YYYY-MM-DD>/<HH-MM-SS.mmm>.jpg` in the
  existing `hnvr` bucket. Presigning uses the **ro** keypair
  (`s3cRoAccessKey`), same as event thumbnails.
- **Producer**: node-side. The analysis pipeline already decodes the
  sub-stream (`FrameSource`); a new `Hnvr.Node.SnapshotWriter` taps one
  decoded frame every `cameras.snapshot_interval_sec`, JPEG-encodes via the
  *existing* event-thumbnail encoder path (the one that produces
  `events.thumbnail_key` bbox JPEGs — same resolution, no overlay), uploads
  to S3, and publishes a `SnapshotWritten` message on `hnvr.events`
  (cr*-style prefix so it can't decode as `CvEvent`/`SegmentWritten` — same
  trick as `ClipReady`). `EventWriter` (or a small dedicated writer) inserts
  the row. Publish-then-insert keeps NATS the single spine; DB write
  failures only cost a snapshot.
  - Sub-stream decode is already running whenever analysis is enabled; the
    tap is a TVar read + encode, ~zero extra decode cost.
  - `snapshot_interval_sec = 0` disables snapshots for the camera.
  - Camera form gains the interval input (checkbox-absent-NULL pitfall does
    not apply — INT with default).
- **Retention**: `RetentionSweeper` sweeps `camera_snapshots` with the
  camera's `retention_hours` — same prefix-scoped delete pattern as
  `event_clips`. Storage cost at 60 s interval ≈ 1.4 k JPEGs/day/camera
  (640×360 ≈ 30–50 kB → ≈ 60 MB/day/camera) — well inside the existing
  recording budget.
- **Nearest-thumb lookup** (`/TimelineThumb`):
  `WHERE camera_id = ? AND ts <= ? ORDER BY ts DESC LIMIT 1`, reject when
  the row is older than `4 × snapshot_interval_sec` (stale = camera was not
  recording — return 404, tile shows gap placeholder; this doubles as the
  cheap coverage check client-side, but the authoritative gate is the
  coverage spans from `/TimelineData`).

### What stays, what goes

- **Stay**: `/PlayerArchive`, `/PlaylistArchive` (single-camera deep links,
  used by `/Events` rows and now by the timeline's per-camera playback),
  `/PurgeRecording` (reached from a tile context menu: "purge recordings in
  current window" — admin only, same tombstone flow), `/Events`,
  `/PlayerEventClip`.
- **Goes**: `/Archive` recordings table + `Hnvr.Web.View.Archive.Index`
  (sidebar "Archive" points at `/Timeline`; `PurgeRecordingAction`'s
  `returnTo` redirects to `/Timeline` with window params).

### HNVR.yaml / env

Nothing new — S3 via the existing `Hnvr.Core.Config` + `HNVR_S3_*` merge;
interval is a per-camera DB column, not config. Kill switch:
`HNVR_DISABLE_SNAPSHOTWRITER` (pattern of the other role gates).

## Client side (`static/timeline.js`, new; no new deps)

- Plain canvas rendering (same vanilla-JS discipline as `app.js`/`ptz.js`;
  no framework, loaded without `defer` per layout convention).
- Pointer Events API (`setPointerCapture` on the handle) — mouse only in v1.
- Time↔pixel mapping is pure (`t = from + (x/width)·(to−from)`), unit-tested
  via a tiny exported pure module pattern if warranted; otherwise Playwright
  covers it.
- All times rendered through `HNVR.viewerTz()` + `Intl` (never
  `toLocaleString` defaults) — consistent with the v0.12.0.0 timezone work.
- hls.js per tile is already vendored for the archive player; players are
  created lazily on release and destroyed on the next scrub (max ~20
  concurrent hls.js instances is the practical cap — fine for the 6–20
  camera target).
- Thumbnail fetch throttling: one `AbortController` per tile; new scrub
  position aborts the in-flight request. Server-side, `/TimelineThumb`
  responses are 302s with `Cache-Control: private, max-age=30` so rapid
  back-and-forth scrubbing reuses browser cache.

## Failure/edge cases

| Case | Behavior |
|---|---|
| Camera mid-recording at cursor | Playlist builder already handles trailing partial window (existing behavior) |
| Snapshot missing but coverage exists | Tile shows the coverage state; thumb 404 → generic "frame unavailable" placeholder, playback unaffected |
| All cameras disabled | Timeline still scrubs; release = no-op with a hint line |
| Window spans retention boundary | Coverage lanes simply end; events markers stop (retention-swept) |
| >500 events in window per camera | Server buckets to 500 markers (max-count per pixel-bucket, earliest ts wins) + `truncated: true` flag |
| Clock skew / future cursor | Range end clamped to `now` server-side |

## Testing

- **Cabal**: pure window/merge logic reuses `Hnvr.Core.Recording` tests;
  new pure module `Hnvr.Core.Timeline` (span merge for JSON, marker
  bucketing, nearest-snapshot pick) with QuickCheck alongside the existing
  suites. Snapshot-interval → expected-storage property test optional.
- **Playwright** (`timeline.spec.ts`): page loads with 24 h window; cursor
  drag updates thumb img `src`; release issues playlist requests for
  enabled cameras only; disable toggle persists across reload
  (localStorage); event marker click seeks. Follow the existing
  role-disabled leader pattern on :18002 (`HNVR_DISABLE_*`).
- **Live verification**: one camera with `snapshot_interval_sec = 10`,
  confirm rows + S3 objects + sweeper deletes, then reset to 60.

## Rollout phases (all landed)

1. **A — snapshot pipeline** ✅ v0.13.0.0: migration 0013,
   `Hnvr.Node.SnapshotWriter` (analysis-sink tap, forkIO encode/upload/
   publish), `SnapshotWritten` → EventWriter → `camera_snapshots`,
   sweeper extension, camera form input.
2. **B — timeline read path** ✅ v0.13.0.0: `/Timeline` shell,
   `/TimelineData`, `/TimelineThumb`, canvas rendering, scrub
   thumbnails, toggles, deep links.
3. **C — sync playback + cutover** ✅ v0.14.0.0: per-camera hls.js on
   cursor release (teardown on next scrub), tile purge button →
   `/PurgeRecording` redirects to `/Timeline`, `/Events` ▶ links
   repointed, sidebar "Archive" → `/Timeline`, recordings table +
   `Hnvr.Web.View.Archive.Index` removed, `timeline.spec.ts` (8 tests).
