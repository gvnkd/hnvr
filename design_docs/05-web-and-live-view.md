# HNVR — Web UI & Live View

Web layer is IHP (pinned to a `master` commit supporting GHC 9.12). Live video is delegated to MediaMTX (WebRTC WHEP) running **on the leader host only** (hnvr-2, RTX 4090). The IHP app renders HTML, manages config, generates HLS playlists for archive, and reverse-proxies the WHEP endpoint.

## IHP application structure

```
hnvr-web/
├── Main.hs                       -- entry, runs IHP runServer (leader-only)
├── Config/Config.hs              -- env-driven IHP config
├── static/
│   ├── hls.js                    -- vendored, HLS.js for fallback player
│   ├── chart.js                  -- dashboard
│   └── app.css                   -- tailwind via IHP default
├── Application/Schema.sql        -- IHP schema (see 06-data-model.md)
├── Web/
│   ├── FrontController.hs        -- routes
│   ├── Controller/
│   │   ├── Cameras.hs            -- CRUD cameras; triggers NATS config broadcast
│   │   ├── Rules.hs              -- CRUD line/zone rules
│   │   ├── Live.hs               -- /live/<slug>
│   │   ├── Archive.hs            -- /archive/<slug>?from=..&to=..
│   │   ├── Events.hs             -- /events?cam=..&from=..&class=..
│   │   ├── Dashboard.hs          -- / (cameras overview grid + host health)
│   │   ├── Hosts.hs              -- /hosts (status of hnvr-1, hnvr-2)
│   │   └── Api.hs                -- /api/* JSON for future SPA / automation
│   └── View/
│       ├── Layout.hs             -- nav, side menu
│       ├── Dashboard/
│       ├── Cameras/
│       ├── Rules/
│       ├── Live/
│       ├── Archive/
│       ├── Events/
│       └── Hosts/
└── Web/Router.hs                 -- route generators
```

## Authentication & users

IHP's built-in auth (`IHP.AuthSupport`):

- `users` table with `email`, `password_hash`, `role`, `locked_at`, `failed_login_attempts`.
- `BeforeValidatedAccess` filter — every controller action requires login.
- Roles: `admin` (full), `viewer` (live + archive + events only).

First-run bootstrap: an `admin` user is created from `INITIAL_ADMIN_EMAIL` / `INITIAL_ADMIN_PASSWORD` env vars (set via systemd `EnvironmentFile=` from sops-nix). Subsequent users via UI.

## URL map

> **Implementation note (Aug 10 2026, commit `ce739c1`)** — the table
> below is the design target: RESTful, slug-in-path. The current impl
> uses IHP-canonical action-derived URLs instead (`/Cameras`,
> `/ShowCamera?cameraId=…`, `/EditCamera?cameraId=…`, `/CreateCamera`,
> `/UpdateCamera?…`, `/DeleteCamera?…`, `/ProbeCamera?…`,
> `/AssignCamera?…`, `/PlayerArchive?cameraId=…`,
> `/PlaylistArchive?cameraId=…`, `/ShowLive?cameraId=…`, `/Hosts`,
> `/Dashboard`). IHP's `AutoRoute` derives URLs from constructor names,
> and the initial Phase 1/2 slices used the canonical form to avoid
> `/Index` collisions across controllers and to get `startPage` working
> at `/`. Migration to the RESTful form below is deferred to Phase 8
> (Polish) — either via custom `AutoRoute` instances or a `Yesod`-style
> `pathComponents` override. See `.opencode/MEMORIES.md` pitfall #59
> for the IHP `actionPrefixText` gotcha that drove the canonical
> naming. The WHEP proxy (`/whep/:slug`) is unaffected — it's raw WAI
> middleware, not an IHP controller.

| Method | Path | Controller / Action | Auth |
|--------|------|---------------------|------|
| GET    | `/`                       | Dashboard#index        | viewer+ |
| GET    | `/hosts`                  | Hosts#index            | viewer+ |
| GET    | `/cameras`                | Cameras#index          | viewer+ |
| GET    | `/cameras/new`            | Cameras#new            | admin |
| POST   | `/cameras`                | Cameras#create         | admin |
| GET    | `/cameras/:id/edit`       | Cameras#edit           | admin |
| PATCH  | `/cameras/:id`            | Cameras#update         | admin |
| DELETE | `/cameras/:id`            | Cameras#delete         | admin |
| POST   | `/cameras/:id/assign`     | Cameras#assign         | admin | override `assigned_host`
| GET    | `/rules`                  | Rules#index            | viewer+ |
| POST   | `/rules`                  | Rules#create           | admin |
| GET    | `/cameras/:slug/presets`  | Presets#index          | viewer+ |
| POST   | `/cameras/:slug/presets`  | Presets#create         | admin |
| DELETE | `/cameras/:slug/presets/:id` | Presets#destroy     | admin |
| POST   | `/cameras/:id/ptz`        | Cameras#ptz            | admin (or viewer if `ptz_viewer_control`) |
| GET    | `/live/:slug`             | Live#show              | viewer+ |
| ANY    | `/whep/:slug`             | (proxy to MediaMTX)    | viewer+ |
| GET    | `/archive/:slug`          | Archive#index          | viewer+ |
| GET    | `/archive/:slug/playlist.m3u8` | Archive#playlist  | viewer+ |
| GET    | `/archive/:slug/clip`     | Archive#export         | viewer+ |
| GET    | `/events`                 | Events#index           | viewer+ |
| GET    | `/events/:id/thumb`       | Events#thumb           | viewer+ |
| GET    | `/api/v1/events.json`     | Api#events             | viewer+ (token) |
| GET    | `/metrics`                | (EKG / Prometheus)     | localhost only |

## Live view page

```hsx
-- Web/View/Live/Show.hs
instance View ShowView where
    html ShowView { camera, whepUrl, assignedHost } = [hsx|
        <div class="live-grid">
            <video id="player" autoplay muted playsinline></video>
            <script type="module">
              import { WHEPClient } from '/static/whep.js';
              const pc = new RTCPeerConnection();
              pc.addTransceiver('video', { direction: 'recvonly' });
              pc.addTransceiver('audio', { direction: 'recvonly' });
              pc.ontrack = e => document.getElementById('player').srcObject = e.streams[0];
              const whep = new WHEPClient('/whep/{camera.slug}');
              await whep.view(pc);
            </script>
            <div class="overlay">
                <h2>{camera.name}</h2>
                <span class="badge">Host: {assignedHost}</span>
                {renderEventFeed camera.slug}
            </div>
        </div>
    |]
```

- `whep.js`: ~50 LOC browser-native WHEP client (RTCPeerConnection + fetch SDP offer → POST to `/whep/<slug>` → set SDP answer). No npm.
- `/whep/<slug>`: IHP action that reverse-proxies to `http://127.0.0.1:8889/<slug>/whep` (MediaMTX's WHEP endpoint, on leader host).

### Live event feed on the same page

The right panel shows live events for the current camera via IHP `autoRefresh`. Two equivalent implementations; pick based on traffic:

**v1 (simple)** — autorefresh queries Postgres directly:

```hsx
action LiveEventFeedAction { slug } = autoRefresh do
    events <- query @Event
        |> filterWhere (#cameraSlug, slug)
        |> orderByDesc #createdAt
        |> limit 20
        |> fetch
    render LiveEventFeedView { .. }
```

**v1.1 (lower Postgres load)** — autorefresh action subscribes to NATS `hnvr.events` filtered by camera, holds the subscription for the duration of the SSE connection:

```haskell
action LiveEventFeedAction { slug } = do
    chan <- liftIO $ natsSubscribeFiltered "hnvr.events" (matchesCam slug)
    autoRefreshCustom $ \emit -> forever $ do
        e <- readTChan chan
        emit (renderEventRow e)
```

Either works. Start with v1 simple.

## PTZ control (live view, only shown when `camera.ptz_enabled=true`)

Right-hand panel of `/live/<slug>` shows a PTZ control widget when the camera has `ptz_enabled=true`. Hidden otherwise.

### Layout

```
┌──────────────────────────────────────────┐
│ PTZ - {camera.name}              [status] │
│                                          │
│           ┌─────────────────┐            │
│           │      ▲          │            │
│           │      ▲          │            │
│           │  ◀       ▶       │            │
│           │      ▼          │            │
│           │      ▼          │            │
│           └─────────────────┘            │
│                                          │
│   Zoom:  [−]  ━━━━━━━●━━━━━━━  [+]      │
│                                          │
│   Presets: [Dropdown ▾] [Go] [Save] [×]  │
│             1. Door                      │
│             2. Parking                   │
│             3. Gate (home)               │
│                                          │
│   [⌂ Home]   [⏹ Stop]   [ ⓘ Info ]      │
└──────────────────────────────────────────┘
```

### Joystick behavior

- Each of the 8 directional buttons issues `ContinuousMove(vx, vy, 0)` with the speed proportional to how long the click is held (200 ms ramp from 0.1 → 0.5 by default).
- Release (`mouseup` / `mouseleave`) issues `Stop`.
- On touch devices, the same buttons work as touchstart/touchend.
- Implementation: ~80 LOC of vanilla JS in `static/ptz.js` using `fetch` POSTs to `/cameras/:id/ptz`. No npm.

### Server side

```haskell
action PtzAction { cameraId } = do
    camera <- fetch cameraId
    accessDeniedUnless (camera.ptzEnabled &&
                        (currentUser.role == Admin || camera.ptzViewerControl))
    cmd    <- paramOrValidationFailed "command"  -- continuous_move|stop|goto_preset|...
    args   <- paramJson "args"
    -- publish to host owning the camera
    natsPublish ("hnvr.commands.ptz." <> camera.slug)
                (encode PtzCommand { command = cmd, args = args
                                   , source = "web_ui", userId = Just currentUserId })
    -- audit (asynchronously via EventWriter)
    publishAudit cameraId currentUserId cmd args
    renderPlain "ok"
```

### Preset management

`/cameras/:slug/presets` shows all presets, allows:
- **Set new**: button issues `SetPreset(name)` → ONVIF returns token → row in `ptz_presets` with `onvif_token`, position snapshot from `GetStatus`.
- **Rename**: just updates `name` locally (ONVIF token stays).
- **Go**: button issues `GotoPreset(token)`.
- **Make home**: checkbox sets `is_home=true` and `cameras.ptz_home_preset_id`.
- **Delete**: `RemovePreset(token)` then row delete.

### PTZ status indicator

Top of the PTZ panel shows the camera's current state, polled via `autoRefresh` (1 Hz):

- `Idle`, `ManualMove`, `GoingToPreset`, `ReturningHome`, `AutoTracking` (v1.1).
- Last command timestamp + duration.

State source: the host owning the camera publishes `hnvr.ptz.status.<cam>` every state change + every 2 s heartbeat. Leader caches latest value in `IORef` for fast reads.

### Manual control preempts auto-track (v1.1)

When auto-track is enabled and the operator clicks any PTZ button, the PtzController transitions `AutoTracking → ManualMove` immediately. Auto-track resumes only when the operator clicks the "Resume auto-track" toggle.

## MediaMTX integration

### Configuration sync

`MediaMTXConfigSyncer` (leader-only async thread) listens on Postgres LISTEN on `cameras_events` channel; whenever a camera row changes, regenerates `/run/hnvr/mediamtx.yml` from the IHP-stored cameras and `SIGHUP`s MediaMTX (live reload).

Generated YAML:

```yaml
# /run/hnvr/mediamtx.yml (managed by hnvr-leader, do not edit)
apiVersion: 1.20.0

##################################
# Camera definitions (from Postgres)
paths:
  cam-196:
    source: rtsp://admin:XXXX@192.168.0.196:554/user=admin&password=...&stream=MainStream
    sourceProtocol: tcp
    sourceOnDemand: yes          # only pulls when a client is watching
    hlsAlwaysRemux: no
  cam-197:
    source: rtsp://...
  cam-198:
    source: rtsp://...

##################################
# Server listeners
api: yes
apiAddress: :9997
hlsAlwaysRemux: no
webrtc: yes
webrtcAddress: :8889
webrtcAllowOrigin: '*'
webrtcEncryption: no
```

`sourceOnDemand: yes` is the key — MediaMTX only connects to a camera when a browser is watching. 20 cameras in Postgres costs nothing unless someone is live-viewing.

**Cross-host optimization (post-v1)**: run MediaMTX on each host, route WHEP to the host already pulling the camera. Skipped in v1 to keep one MediaMTX config in one place.

### Reverse proxy (nginx on leader)

```
/whep/<slug>          → MediaMTX WHEP POST endpoint
/live/<slug>/webrtc   → MediaMTX /<slug> WebRTC over WS (alt. transport)
```

Cookies set by IHP login are passed through; the proxy layer trusts the boundary.

### Password substitution

The YAML is rendered **with credentials**; `mediamtx.yml` lives at `/run/hnvr/mediamtx.yml` (systemd `RuntimeDirectory=hnvr`), `0600`, owned by `hnvr`. Decrypted passwords come from the in-memory camera config cache.

## Archive playback

### Time-range playlist generation

```
GET /archive/cam-196/playlist.m3u8?from=2026-08-07T14:00:00Z&to=2026-08-07T15:00:00Z
```

IHP action:

1. Parse `from`/`to` (validate ≤ 6 hours apart — longer windows require export).
2. `SELECT object_key, start_ts, end_ts FROM segments WHERE camera_id=? AND start_ts >= ? AND end_ts <= ? ORDER BY start_ts`.
3. For each segment, generate a presigned SeaweedFS URL valid for 1 hour. Presign against `HNVR_S3_PUBLIC_ENDPOINT` when set (falling back to `HNVR_S3_ENDPOINT`); the signed URL's host is part of the SigV4 signature and must be reachable by the browser.
4. Render m3u8:

```
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-TARGETDURATION:2
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:1.000,
<presigned-url-seg1>
#EXTINF:1.000,
<presigned-url-seg2>
...
#EXT-X-ENDLIST
```

5. `Content-Type: application/vnd.apple.mpegurl`, `Cache-Control: private, max-age=0`.

The browser loads this in `<video src="..."  controls>` via `hls.js` (Safari handles HLS natively but we don't ship HEVC HLS for Safari in v1). fMP4 fragments are directly playable as HLS segments thanks to our `+frag_keyframe+empty_moov+default_base_moof` flags at capture time.

### Visual timeline

A horizontal timeline above the player shows:

- Density of segments (gaps visible as breaks).
- Color ticks for events (red = line crossed, blue = zone enter).
- Scrubbing changes `from`/`to`.

Built with custom `<canvas>` + htmx polling for events. ~200 LOC of JS in `static/timeline.js`.

### Clip export

`POST /archive/cam-196/clip` with `{ from, to }`:

1. Enqueue an `ExportJob` row.
2. `ExportWorker` (leader-only async) uses `ffmpeg -f concat -safe 0 -i list.txt -c copy out.mp4` where `list.txt` lists presigned URLs. ~5 s per hour of video (zero re-encode).
3. Upload to `hnvr-exports/<job-uuid>.mp4`, presigned URL returned to user, valid 24 h.
4. Sweep deletes `hnvr-exports` objects older than 24 h.

## Events view

```
GET /events?cam=cam-196&from=...&to=...&kind=LineCrossed&class=0
```

- Filter form (htmx-driven filters).
- Table: timestamp, camera, host, kind, class, thumbnail (click to play the segment), track ID.
- Click thumbnail → `/archive/<slug>?t=<ts>` deep-link with auto-seek.

Behind the scenes: `SELECT ... FROM events WHERE ... ORDER BY ts DESC LIMIT 200`. BRIN on `ts` + btree on `(camera_id, ts DESC)` keep this fast even at 10M+ events/year.

## Dashboard `/`

- Grid of camera cards: live thumbnail (polled via `autoRefresh` every 10 s; JPEG from MediaMTX's `/<slug>/preview.jpg`).
- Per-camera event count in last hour.
- Top-level stats: storage used, free space (queried from SeaweedFS), aggregate fps, host CPU/GPU.
- **Per-host panel**: shows hnvr-1 and hnvr-2 with current camera assignments, CPU%, GPU mem, last health ts. Backed by `hnvr.health.<host>` consumed via NATS subscription.

## Hosts view `/hosts`

- Per-host status: leader vs. node, cameras assigned, GPU model + EP, current fps, frame drops, last 24h event count.
- Manual reassignment UI: drag camera card between hosts (writes `cameras.assigned_host`, broadcasts NATS command).
- Force-restart worker button: publishes `hnvr.commands.control.<host>.<cam>.restart`.

## Realtime config → workers

When an admin edits a camera or a rule:

1. IHP controller `PATCH /cameras/:id` updates Postgres row.
2. Same transaction fires `NOTIFY cameras_events` (Postgres LISTEN/NOTIFY trigger).
3. Listeners (all on leader):
   - `MediaMTXConfigSyncer`: regenerates `mediamtx.yml` + SIGHUPs MediaMTX.
   - `ConfigBroadcaster`: publishes `hnvr.config.cameras.<slug>` JSON to NATS.
   - `AssignmentCoordinator`: if `assigned_host` changed, publishes `hnvr.commands.assign.<slug>`.
4. Each host's `ConfigWatcher` (NATS subscriber) updates its in-memory `IORef (Map CameraId Camera)`; the affected `CaptureSupervisor` starts/stops/restarts the worker.
5. Rules updates republish the camera's full assign payload (`hnvr.commands.assign.<slug>`) — the owning host restarts the analysis pair with the fresh rule set. (The once-planned `hnvr.config.rules.<cam>` subject was dropped in v0.5.2.0 — never implemented, superseded by the full-snapshot assign.)

No service restart needed for routine config changes.

## Performance targets

- `/archive/.../playlist.m3u8` for a 1-hour window: P99 < 50 ms (3600 segments × simple render).
- `/events?from=...&to=...`: P99 < 100 ms (BRIN + btree index).
- Live view TTFP (time to first picture): < 1.5 s from page load.
- Memory: IHP webserver fits in 256 MB RSS under normal load.

## What we explicitly do NOT build (v1)

- Multi-camera synchronized playback (post-v1, would need clock skew handling).
- Native mobile app.
- Per-camera ACL (admin/viewer is enough for v1).
- Email/Telegram/Mattermost alert delivery (a webhook out is enough; integration is a config setting).
- Standby web node (post-v1 — leader election plumbing exists, second node not deployed).
