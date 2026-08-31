# HNVR — Computer Vision Pipeline

This document covers everything between "raw RGB frame from CaptureWorker" and "`Event` published on NATS".

## End-to-end pipeline

```
Frame (sub-stream native res, e.g. 640×480 RGB, 5 fps, wall-clock ts)
  │                                            ┌──── runs on hnvr-1 (GTX 1070) ────┐
  │                                            │     CPU EP (cuDNN ≥ 9.12 dropped   │
  │                                            │     Pascal — no CUDA/TRT)          │
  │                                            ├──── runs on hnvr-2 (RTX 4090) ────┤
  │                                            │     TensorRT EP, ~1 ms/frame      │
  │                                            └────────────────────────────────────┘
  ▼
┌──────────────────────────────────────────────────────────────┐
│ 1. Preprocess                                                 │
│    - letterbox to YOLO input (320×320 or 640×640)             │
│    - NHWC → NCHW transpose                                    │
│    - normalize: x / 255.0                                     │
│    - stash sub-stream native dims for post-processor          │
│    (No up-front downscale — sub-stream is already small.      │
│     If sub-stream disabled, frame arrives already 640×360     │
│     via the fallback -vf scale in ffmpeg; same code path.)    │
└──────────────────────────────────────────────────────────────┘
  │
  ▼ Tensor (massiv Array S B (Ix3 1 3 320 320))
┌──────────────────────────────────────────────────────────────┐
│ 2. ONNX Runtime inference                                     │
│    - YOLOv8n model, input 'images', outputs 'output0'         │
│    - EP chosen by host:                                        │
│       hnvr-1 → [CPUExecutionProvider]                           │
│       hnvr-2 → [TensorrtExecutionProvider, CUDAExecutionProvider, CPUExecutionProvider] │
└──────────────────────────────────────────────────────────────┘
  │
  ▼ raw [1, 84, 2100] float32 (pre-NMS YOLOv8 output)
┌──────────────────────────────────────────────────────────────┐
│ 3. Decode + NMS (pure Haskell)                                │
│    - For each anchor: cx, cy, w, h, class scores              │
│    - Filter by conf threshold (per-camera, default 0.35)      │
│    - Per-class NMS@IoU 0.45                                   │
│    - Rescale boxes back to 640×360 letterbox coords           │
└──────────────────────────────────────────────────────────────┘
  │
  ▼ Vector Detection (cx, cy, w, h, classId, score)
┌──────────────────────────────────────────────────────────────┐
│ 4. Tracker update (SORT)                                      │
│    - Predict existing tracks via Kalman                       │
│    - Match detections ↔ tracks (Hungarian on IoU)             │
│    - Update matched, age unmatched, birth new                 │
└──────────────────────────────────────────────────────────────┘
  │
  ▼ Vector Track (id, cx, cy, w, h, classId, score, vx, vy)
┌──────────────────────────────────────────────────────────────┐
│ 5. Rules engine                                               │
│    - For each rule on this camera:                            │
│      * line crossing: did trackId cross segment since last t? │
│      * zone intrusion: is track inside polygon (and wasn't)?  │
│    - Emit Event on transitions only                           │
└──────────────────────────────────────────────────────────────┘
  │
  ▼ Event
  to in-process publisher → NATS "hnvr.events" (core NATS, fire-and-forget)
  → leader's EventWriter → Postgres
```

## ONNX Runtime Haskell binding

**Do not** depend on `hs-onnxruntime-capi` from Hackage — it's stale and won't build on GHC 9.12. Write our own minimal binding (~150 LOC) in `Hnvr.Cv.OnnxRuntime`, calling the C API directly:

```c
// onnxruntime_c_api.h — the API is a single vtable:
const OrtApi* OrtGetApiBase(void)->GetApi(uint32_t version);
// Then OrtApi* holds ~80 function pointers (CreateEnv, CreateSession, Run, ...).
```

The Haskell side loads the vtable once via `dlsym`, wraps each function pointer in `foreign import ccall dynamic`. ~150 LOC total in `Hnvr.Cv.OnnxRuntime.Internal`. Public API in `Hnvr.Cv.OnnxRuntime`:

```haskell
data Session        -- opaque
data ExecutionProvider = CPU | CUDA | TensorRT

withSession :: Maybe Text                  -- model_path (.onnx or .engine)
            -> [ExecutionProvider]         -- priority order
            -> (Session -> IO r) -> IO r
infer      :: Session -> Tensor -> IO Tensor
```

Stable across ONNX Runtime versions (the C API explicitly supports this pattern). Lives in `hnvr-cv`.

### Per-host EP selection

Resolved at startup from env var `HNVR_EXEC_PROVIDERS` (comma-separated; defaults from NixOS module):

| Host | Default `HNVR_EXEC_PROVIDERS` |
|------|-------------------------------|
| hnvr-1 | `cpu` |
| hnvr-2 | `tensorrt,cuda,cpu` |

First EP that initializes successfully wins. TensorRT 10 dropped Pascal, and cuDNN ≥ 9.12 dropped Pascal too — so on hnvr-1 (GTX 1070) only the CPU EP is viable. CPU EP is always available as last resort.

### Session lifecycle

One ONNX session per AnalyzerWorker (one per camera). Sessions are not shared across workers — keeps per-camera isolation, and we never hit session-thread-safety issues. Held in a strict `IORef` in the worker.

Memory: YOLOv8n session ≈ 12 MB on CPU, ≈ 30 MB on CUDA, ≈ 80 MB on TensorRT (engine workspace). 10 cameras × 80 MB = 800 MB GPU memory on RTX 4090 — trivial. hnvr-1 runs CPU-only, so its GTX 1070 VRAM is unused by inference.

## TensorRT engine cache (Aug 13 2026 — supersedes "trtexec pre-build")

The original plan was to pre-build engines offline with `trtexec` in CI.
In practice: CI runners have no GPU, so sm_89 engines can't be built
there. Instead the analyzer enables ORT TRT EP's own engine cache
(`trt_engine_cache_enable` + `trt_engine_cache_path` via
`HNVR_TRT_CACHE_DIR`): the first analyzer start on a host builds the
engine (~1 min for yolov8n-320 / ~2 min for yolov8s-640) and every
later session cache-hits (~1 s). Cache is keyed by model content + TRT
version + GPU arch, so all cameras sharing one model share one engine.

The nixpkgs onnxruntime build needed `onnxruntime_USE_TENSORRT=ON` +
`onnxruntime_USE_TENSORRT_BUILTIN_PARSER=ON` (see MEMORIES pitfall #104).

For GTX 1070 (Pascal, `sm_61`), TensorRT 10 support is dropped — AND
cuDNN ≥ 9.12 dropped Pascal too, so the CUDA EP is also unavailable
(pitfall #103). hnvr-1 runs the CPU EP in v1.

## Model: YOLOv8n

- Train via Ultralytics, export:
  ```
  yolo export model=yolov8n.pt format=onnx imgsz=320 opset=17 simplify=True dynamic=False
  ```
- Input: `images` tensor `[1, 3, 320, 320]`, float32, normalized 0..1.
- Output: `output0` tensor `[1, 84, 2100]` — 2100 anchors × (4 box + 80 COCO classes).
- Latency targets:
  - RTX 4090 + TensorRT FP16: **~1 ms**
  - GTX 1070 + CPU EP (no CUDA on Pascal anymore): **~10 ms**
  - i7-12700 + CPU: **~10 ms**

Class filter at decode time keeps the model's 80 classes intact but skips work for discarded classes:

```haskell
keepClasses :: Word8 -> Bool
keepClasses c = c `elem` [0, 1, 2, 3, 5, 7]  -- person, bicycle, car, motorcycle, bus, truck
-- configurable per rule via rules.classes INT[]
```

For RTX 4090 host with cycles to spare, swap to YOLOv8s-640 per-camera — see `cameras.model_name` config.

## Preprocess with `massiv`

```haskell
-- input: Frame { width=W, height=H, rgb=ByteArray (W*H*3) }
--   W,H = sub-stream native resolution (e.g. 640×480), OR
--         640×360 when sub-stream fallback to main-stream-with-scale is active
-- output: Array S B (Ix3 1 3 320 320) Float

preprocess :: Frame -> Array S B (Ix3 1 3 320 320) Float
preprocess = letterbox 320 320
           . fromRgbFrame
           . fmap (/ 255)
```

`letterbox` does `scale + pad` matching Ultralytics' preprocessing — same code path regardless of input resolution. The analyzer doesn't care if the frame came from a 640×480 sub-stream or a 640×360 fallback-scaled main stream; both go through the same YOLO input prep.

## NMS in Haskell

Vanilla NMS, ~60 LOC. Inputs: `Vector (Detection Float)`, IoU threshold (default 0.45), max detections per class (default 100). Uses `Data.Vector.Algorithms.Intro` (sort) and `Data.Vector.Unboxed.Mutable`.

## Tracker: SORT in Haskell

Reference: Bewley, "Simple Online and Realtime Tracking", ICIP 2016. Pure-Haskell in `Hnvr.Cv.Tracker.Sort`.

### State per track

```haskell
data Track s = Track
  { tId               :: !TrackId
  , tKalman           :: !(Kalman6x4 s)         -- state: x,y,s,r,dx,dy  / meas: x,y,s,r
  , tHits             :: !Int
  , tTimeSinceUpdate  :: !Int
  , tAge              :: !Int
  , tClass            :: !Word8
  , tLastBox          :: !Box                    -- last measurement, for rule eval
  , tPerRuleState     :: !(IntMap RuleState)     -- rule_id → cooldown / zone state
  }
```

`Kalman6x4` is a small wrapper over `massiv`'s `Matrix` for the 6×6 state covariance and 4×6 measurement matrix. ~80 LOC linear algebra.

### Association

Hungarian via `hungarian-algorithm-1.0.0`. Cost = `1 - IoU` between predicted track boxes and new detections. Gate at IoU 0.3 (lower ⇒ unmatched).

### Birth/death

- Tentative → confirmed on 3 consecutive hits (eligible for events).
- Killed after 30 missed frames (`max_age`).
- Tracker knobs are env-tunable at analyzer start (0.25.6):
  `HNVR_SORT_MAX_AGE` (frames, default 30 — the "track buffer"),
  `HNVR_SORT_MIN_HITS` (default 3 — the "init threshold"),
  `HNVR_SORT_IOU_GATE` (default 0.3).
- Killed tracks emit nothing — the `track_start`/`track_end` lifecycle
  events were pruned from the `event_kind` enum in migration 0010 (zero
  emitters ever shipped).

## Rules engine

### Data types

```haskell
data Rule
  = LineRule
      { rId         :: !RuleId
      , rCamera     :: !CameraId
      , rLine       :: !(V2 Double, V2 Double)   -- endpoints in normalized coords
      , rDirection  :: !Sign                       -- Positive, Negative, Any
      , rClasses    :: !(Set Word8)
      , rCooldownMs :: !Int
      }
  | ZoneRule
      { rId         :: !RuleId
      , rCamera     :: !CameraId
      , rZone       :: ![V2 Double]                -- polygon (CCW)
      , rMode       :: !ZoneMode                   -- Enter, Exit, Inside
      , rClasses    :: !(Set Word8)
      , rCooldownMs :: !Int
      }
  | ZoneMotionRule                                -- shipped, migration 0005
      { rId         :: !RuleId
      , rCamera     :: !CameraId
      , rZone       :: ![V2 Double]
      , rMinDisplacement :: !Double                -- normalized; track must
      , rClasses    :: !(Set Word8)                -- move at least this far
      , rCooldownMs :: !Int                        -- inside the zone to fire
      }
```

All coordinates normalized (0..1) — independent of analysis resolution. UI draws on top of a 640×360 still from MediaMTX.

### Line crossing

Per track, store previous center `p0` and current center `p1`. Compute segment intersection of `(p0, p1)` with rule line segment. If intersect:

1. Cross product of line direction and motion vector → sign.
2. If sign matches `rDirection` and class ∈ `rClasses` and `now - last_emit(track, rule) > cooldown`: emit.

~30 LOC.

### Zone intrusion

Point-in-polygon (ray casting). Per track:
- compute `inside_now = pointInPoly center rZone`
- compare with `inside_prev` stored in `tPerRuleState`
- emit `Enter`/`Exit`/`Inside` events based on `rMode`

### Cooldowns

Per-rule state in `tPerRuleState :: IntMap RuleState` on each track. Prune entries when track dies.

Since 0.25.6 the cooldown is ALSO a rule-level refractory
(`EngineState.esRuleLastEmit`): a rule emits at most one event per
cooldown window regardless of which track triggered it. Per-track
cooldown + id-switch adoption are heuristics that miss real-world
SORT id churn (reappearances scattered beyond the handover radius) —
without the refractory, a whole-frame `zone_inside` rule fired for
every orphaned track id (Aug 2026: ~12k rows, bursts of 8 ids in
40 s on floor_2_5). Trade-off: two genuinely distinct objects
tripping the same rule within one window produce a single event.

## Auto-track consumer (v1.1 milestone)

Auto-track is a **separate consumer** of the tracker output, parallel to the rules engine. Lives in `Hnvr.Cv.AutoTrack`. **Not shipped in v1.0** — manual PTZ only.

### Closed-loop design

```
Tracker output (Vector Track)
  │
  ▼
Target selector
  │  - filter: class in cameras.autotrack_classes (default [0] = person)
  │  - confidence ≥ cameras.confidence
  │  - pick: max by bbox area (largest matching track)
  │  - sticky: keep same track_id while still alive (don't flip-flop)
  │
  ▼  Maybe Track
Error computation (normalized coords)
  │  err_x = track.cx - 0.5
  │  err_y = track.cy - 0.5
  │  err_z = log2(track.area / desired_area)
  ▼
PID controllers (3 independent: pan, tilt, zoom)
  │  dead band: |err| < 0.04 → 0       (prevent jitter)
  │  clamp:     |out| ≤ 0.5            (slow speeds)
  │  rate limit: Δout ≤ 0.15 / frame   (prevent jerk)
  │  i-term windup guard
  ▼
Velocity command
  │  publish hnvr.commands.ptz.<cam>
  │  { command: 'continuous_move'
  │    , args: {vx, vy, zoom}
  │    , source: 'auto_track', user_id: null }
  │  every 200 ms (5 Hz control loop)
  │
  ▼
PtzController on host owning camera
  │  executes ONVIF ContinuousMove
  │  state = AutoTracking
  │
  ▼
Camera mechanical response (100–300 ms latency)
  │
  ▼
Next frame → next tracker update
```

### Loss handling

- If no target matches for `cameras.autotrack_lost_timeout_ms` (default 2000 ms):
  - Issue `Stop` command.
  - State stays in `AutoTracking` for the operator to resume tracking manually, OR
  - After `cameras.autotrack_return_home_after_ms` (default 30000 ms), transition to `ReturningHome`.

### Tunable parameters (per camera)

```sql
ALTER TABLE cameras ADD COLUMN
    autotrack_enabled         BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE cameras ADD COLUMN
    autotrack_classes         INT[] NOT NULL DEFAULT ARRAY[0];  -- person
ALTER TABLE cameras ADD COLUMN
    autotrack_desired_area    REAL NOT NULL DEFAULT 0.15        -- fraction of frame
                          CHECK (autotrack_desired_area BETWEEN 0.01 AND 1.0);
ALTER TABLE cameras ADD COLUMN
    autotrack_pan_pid         JSONB NOT NULL DEFAULT '{"p":0.4,"i":0.05,"d":0.1}';
ALTER TABLE cameras ADD COLUMN
    autotrack_tilt_pid        JSONB NOT NULL DEFAULT '{"p":0.4,"i":0.05,"d":0.1}';
ALTER TABLE cameras ADD COLUMN
    autotrack_zoom_pid        JSONB NOT NULL DEFAULT '{"p":0.2,"i":0.0,"d":0.05}';
ALTER TABLE cameras ADD COLUMN
    autotrack_lost_timeout_ms INT NOT NULL DEFAULT 2000;
ALTER TABLE cameras ADD COLUMN
    autotrack_return_home_after_ms INT NOT NULL DEFAULT 30000;
```

PID constants are per-camera JSONB so they can be tuned per camera model without code changes. UI exposes a tuning panel (admin-only) with a live preview.

### Honest expectations

- ~1–2 weeks of field tuning per camera model to get acceptable behavior.
- First implementations usually over-correct (oscillate) or under-correct (lag). The dead-band + rate-limit + windup-guard triad is what makes it tractable.
- Different camera models have wildly different mechanical latencies and acceleration curves; the ONVIF `GetConfiguration`/`GetConfigurationOptions` calls surface their speed ranges, which we map into our `[−0.5, 0.5]` output.
- **Auto-track is best-effort, not surveillance-grade.** For mission-critical coverage, recommend fixed cameras + zoom-only PTZ rather than pan/tilt tracking.

## Event publishing

```haskell
data Event = Event
  { eCameraId    :: !CameraId
  , eTs          :: !UTCTime
  , eRuleId      :: !(Maybe RuleId)
  , eKind        :: !EventKind         -- LineCrossed | ZoneEnter | ZoneExit | ...
  , eClassId     :: !(Maybe Word8)
  , eTrackId     :: !(Maybe TrackId)
  , eConfidence  :: !(Maybe Float)
  , eBbox        :: !(Maybe NBox)
  , eThumbnailKey:: !(Maybe Text)      -- 'hnvr/cam-196/.../png' (single bucket)
  , eSegmentTs   :: !(Maybe UTCTime)   -- wall-clock second of containing segment
  , eHostId      :: !HostId            -- which host emitted it
  , ePayload     :: !(Maybe Value)
  } deriving (Generic, ToJSON, FromJSON)
```

Publish path:

1. Emit `Event` from AnalyzerWorker.
2. (Optional) Generate thumbnail — take source `Frame`, draw bbox via `JuicyPixels`, PNG-encode, `PutObject` to the `hnvr` bucket, set `eThumbnailKey`.
3. `aeson-encode` the Event → `natsPublish "hnvr.events" bytes`.
4. Core NATS is fire-and-forget (JetStream deferred) — no ack; worker continues.
5. On publish failure (NATS down): in-memory bounded buffer (max 1000), drop-oldest with `hnvr_events_dropped_total` counter.

Leader's `EventWriter` (separate thread on hnvr-2) is a plain core-NATS subscriber on `hnvr.events`; it batches 50 events / 200 ms / whichever first, inserts into Postgres via IHP's query API. It also consumes `SegmentWritten` (→ `segments` rows), `ClipReady` (→ `event_clips` + `event_clip_events`), and the PTZ audit feed (`PtzAuditWriter`).

## GPU acceleration paths

### hnvr-2 (RTX 4090, Ada sm_89)

- Default EP: **TensorRT** with FP16 + pre-built engine.
- Fallback chain: TensorRT → CUDA → CPU.
- Per-camera model override available: `cameras.model_name IN ('yolov8n-320', 'yolov8s-640')`.
- VRAM headroom: 24 GB; 10 cameras × 80 MB = 800 MB used.

### hnvr-1 (GTX 1070, Pascal sm_61)

- Default EP: **CPU** (TensorRT 10 dropped Pascal; cuDNN ≥ 9.12 dropped it too, killing the CUDA EP).
- Fallback chain: CPU only.
- One model: YOLOv8n-320 only — Pascal is too slow for YOLOv8s.
- VRAM: 8 GB, unused by inference (capture/decode only).

### Fallback (any host without Nvidia driver)

- CPU EP — works everywhere.
- ~10 ms/frame on i7-class CPU; sufficient for ≤ 10 cameras at 5 fps per host.

## Performance budget per host (10 cameras each, 5 fps)

50 inferences/sec per host. **Sub-stream decode cost is now ~3–5% CPU per camera, vs ~30–50% for 4K HEVC main-stream decode** — capture host CPU pressure drops substantially.

| Stage | hnvr-1 (CPU) ms | hnvr-2 (TRT) ms | Notes |
|-------|------------------|-----------------|-------|
| ffmpeg sub-stream decode | 0.5 | 0.5 | off-CPU, async pipe read |
| Preprocess | 1.0 | 1.0 | smaller input than before |
| Inference | 10.0 | 1.0 | the big one |
| Decode + NMS | 0.5 | 0.5 | tight `Vector` loop |
| Tracker update | 0.3 | 0.3 | small matrices |
| Rules eval | 0.1 | 0.1 | 1 track × N rules |
| Thumbnail (amortized) | 0.05 | 0.05 | only on events |
| **Per-frame** | **~12.5 ms** | **~3.5 ms** | |
| **Per-host (50 fps)** | **625 ms/s** = 62.5% one core | **175 ms/s** = 17.5% one core | hnvr-1 carries fewer analysis cameras |

CPU savings vs main-stream-decode design: ~25 percentage points per host freed up at 10 cameras each. Useful headroom for adding cameras, upping analysis fps, or running YOLOv8s-640 on RTX 4090.

EKG histogram `hnvr_inference_seconds{host,cam,model,ep}` records actuals. Counter `hnvr_substream_fallback_total{cam}` records fallback events.

## Hot-loop profiling

Targets for the 5 fps × 20 cams = 100 ms total per-frame budget on the busiest host:

| Stage | Target ms | Verify |
|-------|-----------|--------|
| Frame TChan dequeue | <0.01 | `massiv`/`stm` hot path |
| Preprocess | 1.5 | `massiv` `computeAs S` |
| ONNX infer | 5–10 | EP-dependent |
| Decode/NMS | 0.5 | `Data.Vector.Algorithms.Intro` |
| Tracker | 0.3 | tight `IntMap` ops |
| Rules | 0.1 | geometry primitives |
| Publish (async) | <0.1 | fire-and-forget NATS pub |

Any drift → EKG alarm via Prometheus alert.
