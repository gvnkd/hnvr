# HNVR — Data Model

PostgreSQL 18 (provided as external SaaS). Schema lives in `hnvr-web/Application/Schema.sql` (IHP-managed). IHP auto-generates Haskell record types via `SchemaCompiler` — no manual TH, no `FromRow` instances.

We own the schema and migrations; the SaaS provider owns ops (backups, version upgrades, replication, vacuum). Coordinate extension availability with the provider.

## Postgres 18 features we lean on

- **Async I/O backend** — transparent throughput win on the SaaS side.
- **`STORED` generated columns** — for derived fields like `start_date` (PG 18 also introduces virtual GCs but tooling around virtual GCs is still catching up; we use `STORED`).
- **Improved logical replication** — useful if the SaaS offers replicas.
- **BRIN indexes** (since 9.5) — heavy use for time-series tables.
- **`pg_partman` extension** — request from SaaS provider for `events`/`segments` partitioning.

## Schema (SQL)

```sql
-- =========================================================
-- Users / auth (IHP built-in, slightly extended)
-- =========================================================
CREATE TABLE users (
    id              UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    email           TEXT NOT NULL UNIQUE,
    password_hash   TEXT NOT NULL,
    role            TEXT NOT NULL DEFAULT 'viewer'
                    CHECK (role IN ('admin', 'viewer')),
    locked_at       TIMESTAMP WITH TIME ZONE,
    failed_login_attempts INT NOT NULL DEFAULT 0,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- =========================================================
-- Hosts (our own hosts, registered dynamically via NATS)
-- =========================================================
CREATE TABLE hosts (
    id              TEXT PRIMARY KEY,                            -- 'hnvr-1', 'hnvr-2'
    -- display_name dropped in v0.5.2.0 (0010): was written as a copy of id, never read
    gpu_model       TEXT,                                        -- 'RTX 4090', 'GTX 1070' (from nvidia-smi via health payload)
    exec_providers  TEXT[] NOT NULL DEFAULT ARRAY['cpu'],         -- ['tensorrt','cuda','cpu'] (from health payload)
    is_leader       BOOLEAN NOT NULL DEFAULT FALSE,              -- stamped by the leader's HealthCache UPSERT
    last_health_at  TIMESTAMP WITH TIME ZONE,
    health_json     JSONB,                                       -- last hnvr.health payload
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- =========================================================
-- Cameras
-- =========================================================
CREATE TYPE codec_kind AS ENUM ('h264', 'hevc', 'unknown');

CREATE TABLE cameras (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    slug            TEXT NOT NULL UNIQUE,                       -- 'cam-196'
    name            TEXT NOT NULL,
    -- connection (rtsp_url is authoritative)
    -- rtsp_template/port dropped in v0.5.2.0 (0010): templates never had
    -- form inputs (wiped NULL on every Save); port had no logic consumer.
    rtsp_url        TEXT NOT NULL,
    host            INET,
    username        TEXT,
    password_enc    BYTEA,                                       -- AES-256-GCM ciphertext
    password_nonce  BYTEA,                                       -- GCM nonce
    -- sub-stream (lower-res stream used for analysis; saves 4K HEVC decode)
    rtsp_sub_url    TEXT,                                         -- NULL = fall back to rtsp_url with -vf scale
    -- rtsp_sub_template dropped in v0.5.2.0 (0010), same reason as rtsp_template
    use_substream_for_analysis BOOLEAN NOT NULL DEFAULT TRUE,
    substream_codec codec_kind NOT NULL DEFAULT 'h264',          -- typically h264 even when main is hevc
    substream_width INT  CHECK (substream_width  BETWEEN 64 AND 1920),
    substream_height INT CHECK (substream_height BETWEEN 64 AND 1080),
    -- capture params
    codec           codec_kind NOT NULL DEFAULT 'unknown',
    record_audio    BOOLEAN NOT NULL DEFAULT FALSE,
    record_video    BOOLEAN NOT NULL DEFAULT TRUE,
    analysis_enabled BOOLEAN NOT NULL DEFAULT TRUE,
    analysis_fps    INT NOT NULL DEFAULT 5 CHECK (analysis_fps BETWEEN 1 AND 25),
    -- analysis_width/height removed: analysis resolution == sub-stream resolution
    -- (or main-stream resolution when use_substream_for_analysis=FALSE)
    -- CV
    model_name      TEXT NOT NULL DEFAULT 'yolov8n-320',
    confidence      REAL NOT NULL DEFAULT 0.35 CHECK (confidence BETWEEN 0 AND 1),
    kept_classes    INT[] NOT NULL DEFAULT ARRAY[0,1,2,3,5,7],  -- COCO class ids
    emit_track_lifecycle BOOLEAN NOT NULL DEFAULT FALSE,
    -- PTZ (ONVIF Profile PT)
    ptz_enabled         BOOLEAN NOT NULL DEFAULT FALSE,
    ptz_onvif_url       TEXT,                            -- http://192.168.0.196/onvif/device_service
    ptz_username        TEXT,                            -- NULL = reuse camera.username
    ptz_password_enc    BYTEA,                           -- NULL = reuse camera.password_enc
    ptz_password_nonce  BYTEA,
    ptz_profile_token   TEXT,                            -- ONVIF media profile token, probed at config
    ptz_home_preset_id  UUID,                            -- FK added below (forward ref)
    ptz_idle_timeout_s  INT NOT NULL DEFAULT 30
                        CHECK (ptz_idle_timeout_s BETWEEN 0 AND 3600),
    ptz_viewer_control  BOOLEAN NOT NULL DEFAULT FALSE,  -- TRUE = viewers can use PTZ
    -- lifecycle
    enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    retention_days  INT NOT NULL DEFAULT 7 CHECK (retention_days BETWEEN 1 AND 365),
    -- assignment
    assigned_host   TEXT REFERENCES hosts(id),                  -- 'hnvr-1' | 'hnvr-2'
    manual_assign   BOOLEAN NOT NULL DEFAULT FALSE,             -- TRUE = admin-pinned
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
CREATE INDEX cameras_assigned_idx ON cameras (assigned_host) WHERE enabled;

-- =========================================================
-- Rules (line crossing + zone intrusion)
-- =========================================================
CREATE TYPE rule_kind AS ENUM ('line_cross', 'zone_enter', 'zone_exit', 'zone_inside');

CREATE TABLE rules (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    kind            rule_kind NOT NULL,
    -- geometry stored as JSONB (small tables, no perf concern)
    -- line_cross: { "a": [x,y], "b": [x,y], "direction": "positive" }
    -- zone_*:     { "polygon": [[x,y], ...] }
    geometry        JSONB NOT NULL,
    classes         INT[] NOT NULL DEFAULT ARRAY[0,1,2,3,5,7],
    cooldown_ms     INT NOT NULL DEFAULT 5000,
    enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
CREATE INDEX rules_camera_idx ON rules (camera_id) WHERE enabled;

-- =========================================================
-- Segments (1 row per 1-second fMP4 fragment)
-- =========================================================
CREATE TABLE segments (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    start_ts        TIMESTAMP WITH TIME ZONE NOT NULL,
    end_ts          TIMESTAMP WITH TIME ZONE NOT NULL,
    -- PG 18: derived date column for cheap partition pruning / queries
    start_date      DATE GENERATED ALWAYS AS (start_ts::date) STORED,
    host_id         TEXT REFERENCES hosts(id),                  -- which host captured
    object_key      TEXT NOT NULL,                               -- 'cam-196/.../15.mp4'
    bytes           BIGINT NOT NULL,
    sha256          TEXT NOT NULL,
    has_audio       BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    -- uniqueness: one segment per (camera, start_ts)
    UNIQUE (camera_id, start_ts)
);
-- Hot path: time-range scan per camera
CREATE INDEX segments_cam_start_idx ON segments (camera_id, start_ts DESC);
CREATE INDEX segments_start_ts_brin ON segments USING brin (start_ts);

-- =========================================================
-- Events
-- =========================================================
-- v0.5.2.0 (migration 0010): track_start/track_end/segment_written/system
-- were pruned — zero emitters ever existed; segment_written envelopes go
-- to the segments table, not events. zone_motion was added in 0005.
CREATE TYPE event_kind AS ENUM
    ('line_crossed', 'zone_enter', 'zone_exit', 'zone_inside', 'zone_motion');

CREATE TABLE events (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    rule_id         UUID REFERENCES rules(id) ON DELETE SET NULL,
    ts              TIMESTAMP WITH TIME ZONE NOT NULL,
    kind            event_kind NOT NULL,
    class_id        INT,                                          -- COCO id; null for system
    track_id        INT,
    confidence      REAL,
    bbox            JSONB,                                        -- { "x":, "y":, "w":, "h": } normalized
    thumbnail_key   TEXT,                                         -- 'cam-196/.../png' or NULL
    -- denormalized for fast queries without join
    segment_ts      TIMESTAMP WITH TIME ZONE,                    -- wall-clock of containing segment
    host_id         TEXT REFERENCES hosts(id),                   -- emitting host
    payload         JSONB,                                        -- extra data for system events
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
CREATE INDEX events_cam_ts_idx   ON events (camera_id, ts DESC);
CREATE INDEX events_ts_brin      ON events USING brin (ts);
CREATE INDEX events_kind_idx     ON events (kind, ts DESC);  -- plain since 0010 (was: WHERE kind NOT IN ('system','segment_written'))
CREATE INDEX events_track_idx    ON events (camera_id, track_id, ts DESC)
                                  WHERE track_id IS NOT NULL;

-- =========================================================
-- Recording gaps (intervals with no segment)
-- =========================================================
CREATE TABLE recording_gaps (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    from_ts         TIMESTAMP WITH TIME ZONE NOT NULL,
    to_ts           TIMESTAMP WITH TIME ZONE NOT NULL,
    host_id         TEXT REFERENCES hosts(id),
    reason          TEXT,                                        -- 'ffmpeg_exit', 's3_unreachable', 'host_down', ...
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
CREATE INDEX gaps_cam_idx ON recording_gaps (camera_id, from_ts DESC);

-- =========================================================
-- Export jobs
-- =========================================================
CREATE TYPE export_status AS ENUM ('pending', 'running', 'succeeded', 'failed');

CREATE TABLE export_jobs (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    user_id         UUID NOT NULL REFERENCES users(id),
    from_ts         TIMESTAMP WITH TIME ZONE NOT NULL,
    to_ts           TIMESTAMP WITH TIME ZONE NOT NULL,
    output_key      TEXT,                                        -- 'hnvr-exports/<uuid>.mp4'
    bytes           BIGINT,
    status          export_status NOT NULL DEFAULT 'pending',
    error           TEXT,
    expires_at      TIMESTAMP WITH TIME ZONE NOT NULL
                    DEFAULT (NOW() + INTERVAL '24 hours'),
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    completed_at    TIMESTAMP WITH TIME ZONE
);
CREATE INDEX exports_status_idx ON export_jobs (status, created_at);

-- =========================================================
-- Audit log (admin actions only)
-- =========================================================
CREATE TABLE audit_log (
    id              BIGSERIAL PRIMARY KEY,
    user_id         UUID REFERENCES users(id),
    action          TEXT NOT NULL,                               -- 'camera.create', 'rule.delete', ...
    target_type     TEXT NOT NULL,
    target_id       UUID,
    payload         JSONB,
    ts              TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
CREATE INDEX audit_ts_idx ON audit_log (ts DESC);

-- =========================================================
-- PTZ presets (per-camera named positions)
-- =========================================================
CREATE TABLE ptz_presets (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    onvif_token     TEXT,                          -- token returned by camera (stable across renames)
    pantilt_x       REAL,                          -- snapshot of position when set (informational)
    pantilt_y       REAL,
    zoom            REAL,
    is_home         BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (camera_id, name)
);
CREATE INDEX ptz_presets_cam_idx ON ptz_presets (camera_id);
-- cameras.ptz_home_preset_id FK (forward ref earlier in schema)
ALTER TABLE cameras
    ADD CONSTRAINT cameras_ptz_home_preset_fk
    FOREIGN KEY (ptz_home_preset_id) REFERENCES ptz_presets(id) ON DELETE SET NULL;

-- =========================================================
-- PTZ audit log (every PTZ command issued)
-- =========================================================
CREATE TYPE ptz_source AS ENUM ('web_ui', 'auto_track', 'idle_timeout', 'api', 'schedule');

CREATE TABLE ptz_audit_log (
    id              BIGSERIAL PRIMARY KEY,
    camera_id       UUID NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    user_id         UUID REFERENCES users(id),       -- NULL = system-initiated
    command         TEXT NOT NULL,                   -- 'continuous_move','stop','goto_preset','set_preset','remove_preset','absolute_move'
    args            JSONB,                           -- {vx:0.5,vy:0.3,zoom:0.0} or {preset_token:...}
    source          ptz_source NOT NULL,
    duration_ms     INT,                             -- for continuous_move, how long the joystick was held
    ts              TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
CREATE INDEX ptz_audit_cam_ts_idx ON ptz_audit_log (camera_id, ts DESC);

-- =========================================================
-- Postgres LISTEN/NOTIFY triggers
-- =========================================================
CREATE OR REPLACE FUNCTION notify_change() RETURNS trigger AS $$
BEGIN
    PERFORM pg_notify(TG_ARGV[0], NEW.id::TEXT);
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER cameras_notify
    AFTER INSERT OR UPDATE OR DELETE ON cameras
    FOR EACH ROW EXECUTE FUNCTION notify_change('cameras_events');

CREATE TRIGGER rules_notify
    AFTER INSERT OR UPDATE OR DELETE ON rules
    FOR EACH ROW EXECUTE FUNCTION notify_change('rules_events');

CREATE TRIGGER hosts_notify
    AFTER INSERT OR UPDATE ON hosts
    FOR EACH ROW EXECUTE FUNCTION notify_change('hosts_events');

CREATE TRIGGER ptz_presets_notify
    AFTER INSERT OR UPDATE OR DELETE ON ptz_presets
    FOR EACH ROW EXECUTE FUNCTION notify_change('ptz_presets_events');

-- Required extensions (request from SaaS provider if not default)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";       -- uuid_generate_v4()
CREATE EXTENSION IF NOT EXISTS "pgcrypto";        -- backup for uuid gen
CREATE EXTENSION IF NOT EXISTS "pg_partman";      -- partition management
```

## Generated Haskell types (IHP)

IHP auto-generates, in `Generated/Haskell/Types.hs`:

```haskell
data Camera = Camera
  { id              :: !(Id Camera)
  , slug            :: !Text
  , name            :: !Text
  , rtspUrl         :: !Text
  , rtspTemplate    :: !(Maybe Text)
  , host            :: !(Maybe NetAddr)
  , port            :: !Int
  , username        :: !(Maybe Text)
  , passwordEnc     :: !(Maybe ByteString)
  , passwordNonce   :: !(Maybe ByteString)
  -- sub-stream
  , rtspSubUrl      :: !(Maybe Text)
  , rtspSubTemplate :: !(Maybe Text)
  , useSubstreamForAnalysis :: !Bool
  , substreamCodec  :: !CodecKind
  , substreamWidth  :: !(Maybe Int)
  , substreamHeight :: !(Maybe Int)
  -- capture
  , codec           :: !CodecKind
  , recordAudio     :: !Bool
  , recordVideo     :: !Bool
  , analysisEnabled :: !Bool
  , analysisFps     :: !Int
  -- analysisWidth / analysisHeight removed: derived from sub/main stream at runtime
  , modelName       :: !Text
  , confidence      :: !Float
  , keptClasses     :: !(Vector Int32)
  , emitTrackLifecycle :: !Bool
  -- PTZ
  , ptzEnabled        :: !Bool
  , ptzOnvifUrl       :: !(Maybe Text)
  , ptzUsername       :: !(Maybe Text)
  , ptzPasswordEnc    :: !(Maybe ByteString)
  , ptzPasswordNonce  :: !(Maybe ByteString)
  , ptzProfileToken   :: !(Maybe Text)
  , ptzHomePresetId   :: !(Maybe UUID)
  , ptzIdleTimeoutS   :: !Int
  , ptzViewerControl  :: !Bool
  -- lifecycle
  , enabled         :: !Bool
  , retentionDays   :: !Int
  , assignedHost    :: !(Maybe HostId)
  , manualAssign    :: !Bool
  , createdAt       :: !UTCTime
  , updatedAt       :: !UTCTime
  } deriving (Show, Eq, Generic)

data Host = Host
  { id              :: !HostId
  , displayName     :: !Text
  , gpuModel        :: !(Maybe Text)
  , execProviders   :: !(Vector Text)
  , isLeader        :: !Bool
  , lastHealthAt    :: !(Maybe UTCTime)
  , healthJson      :: !Value
  , createdAt       :: !UTCTime
  } deriving (Show, Eq, Generic)
-- plus enums CodecKind, RuleKind, EventKind, ExportStatus
-- plus IHP's CanCreate, CanUpdate, HasField instances
```

## Domain types (hand-written in `hnvr-core`)

```haskell
newtype CameraId = CameraId { unCameraId :: UUID }
  deriving newtype (Eq, Ord, Show, FromJSON, ToJSON, FromField, ToField)

newtype RuleId   = RuleId   { unRuleId   :: UUID } deriving newtype (...)
newtype TrackId  = TrackId  { unTrackId  :: Int   } deriving newtype (...)
newtype HostId   = HostId   { unHostId   :: Text  } deriving newtype (...)
newtype Sha256   = Sha256   { unSha256   :: ByteString } deriving newtype (...)

data Box a = Box { bxX :: !a, bxY :: !a, bxW :: !a, bxH :: !a }
  deriving stock (Eq, Show, Generic, Functor, Foldable, Traversable)
  deriving anyclass (ToJSON, FromJSON)

type NBox = Box Double        -- normalized 0..1

newtype V2 a = V2 { unV2 :: (a, a) }
  deriving stock (Eq, Ord, Show, Generic, Functor)

data Frame = Frame
  { frameWidth  :: !Int
  , frameHeight :: !Int
  , frameTs     :: !UTCTime
  , frameRgb    :: !ByteString        -- width*height*3 bytes
  }

data Detection = Detection
  { detBox    :: !NBox
  , detClass  :: !Word8
  , detScore  :: !Float
  } deriving (Eq, Show, Generic)

data TrackState = TrackState
  { tsTrackId :: !TrackId
  , tsBox     :: !NBox
  , tsClass   :: !Word8
  , tsScore   :: !Float
  , tsVel     :: !(V2 Double)         -- px/sec in normalized coords
  , tsHits    :: !Int
  , tsAge     :: !Int
  } deriving (Eq, Show, Generic)

data Event = Event
  { eCameraId    :: !CameraId
  , eTs          :: !UTCTime
  , eRuleId      :: !(Maybe RuleId)
  , eKind        :: !EventKind
  , eClassId     :: !(Maybe Word8)
  , eTrackId     :: !(Maybe TrackId)
  , eConfidence  :: !(Maybe Float)
  , eBbox        :: !(Maybe NBox)
  , eThumbnailKey:: !(Maybe Text)
  , eSegmentTs   :: !(Maybe UTCTime)
  , eHostId      :: !HostId
  , ePayload     :: !(Maybe Value)
  } deriving (Eq, Show, Generic)
```

## Encryption helpers (`hnvr-core/Crypto.hs`)

```haskell
module Hnvr.Crypto
  ( encryptText, decryptText
  , initKey
  ) where

-- AES-256-GCM via cryptonite
-- Key from env HNVR_DATA_KEY (base64, 32 bytes), provisioned via sops-nix.

encryptText :: Key -> Text -> IO (ByteString, ByteString)  -- (ciphertext, nonce)
decryptText :: Key -> ByteString -> ByteString -> IO Text
```

`password_enc` + `password_nonce` columns store these bytes. `Camera.passwordEnc`/`passwordNonce` are `Maybe` because the field is nullable for cameras with no auth.

## Volume estimates (20 cams, 2 hosts)

| Table | Row size | Growth | Yearly size |
|-------|----------|--------|-------------|
| `cameras` | ~600 B | static | <10 KB |
| `hosts` | ~400 B | static | <1 KB |
| `rules` | ~500 B | static | <10 KB |
| `segments` | ~180 B | 1/cam/sec | ~95 M rows, ~17 GB |
| `events` (CV) | ~250 B | ~5/cam/min | ~50 M rows, ~12 GB |
| `events` (`segment_written`) | ~150 B | 1/cam/sec | ~95 M rows, ~14 GB (or partition out, see below) |
| `recording_gaps` | ~120 B | rare | negligible |
| `export_jobs` | ~300 B | per user action | negligible |
| `audit_log` | ~400 B | per admin action | negligible |

**Mitigation**: partition `events` by month, `segments` by month, using `pg_partman`. The `segment_written` event stream doubles as our segment ledger — but it's heavy enough that we may want a separate `segment_writes` table partitioned independently. Re-evaluate at 6 months in production.

**SaaS coordination**: ensure the provider's plan accommodates ~50 GB/year growth in our DB. Negligible by modern standards.

## Backup strategy

Postgres backups are **the SaaS provider's concern** (we coordinate but don't operate). What we own:

- Schema migration scripts (`Application/Schema.sql` history), version-controlled in this repo.
- A quarterly `pg_dump --schema-only` to verify we can rebuild on a fresh PG 18.
- Configuration exports (admin → "Export Config" → JSON of cameras + rules + users, minus password hashes) for disaster recovery.

SeaweedFS durability is also the provider's concern. We expose usage metrics in the dashboard.

## Migration policy

IHP's schema designer handles forward migrations (`Schema.sql` diff → SQL). For destructive changes:

1. Add the new column nullable.
2. Backfill in app code or one-shot SQL.
3. Add `NOT NULL` once data is consistent.
4. Never rewrite large tables (`segments`, `events`) in a migration — partition + detach instead.
5. Coordinate with SaaS provider for maintenance-window migrations on > 1 M row backfills.
