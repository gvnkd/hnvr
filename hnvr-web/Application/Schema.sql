-- HNVR schema (Phase 1 subset).
--
-- Source of truth for IHP SchemaCompiler. Generated.Types is produced
-- via the IHP schema-compiler tool and committed to the source tree under
-- src/Hnvr/Web/Generated/. Rerun when this file changes.
--
-- Phase 1 scope: cameras + hosts only. rules, segments, events, etc. land
-- in later phases. PTZ columns on cameras are deferred to Phase 5; CV
-- columns to Phase 3.
--
-- NOTE: this file must stay IHP-parseable. IHP's schema parser does NOT
-- accept `CREATE TABLE IF NOT EXISTS` or `DO $$ ... $$` blocks. The
-- idempotent version that the leader's runtime migration actually runs
-- lives in `migrations/0001-initial.sql` — keep both files in sync when
-- changing schema. The migration file is what production deploys use;
-- this file is what IHP codegen uses.
--
-- IMPORTANT: IHP schema parser does not accept comments INSIDE CREATE
-- TABLE bodies. Keep column docs in the module Haddocs or in design_docs.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE hosts (
    id              TEXT PRIMARY KEY,
    gpu_model       TEXT,
    exec_providers  TEXT[] NOT NULL DEFAULT ARRAY['cpu'],
    is_leader       BOOLEAN NOT NULL DEFAULT FALSE,
    last_health_at  TIMESTAMP WITH TIME ZONE,
    health_json     JSONB,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE TYPE codec_kind AS ENUM ('h264', 'hevc', 'unknown');

CREATE TABLE cameras (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    slug            TEXT NOT NULL UNIQUE,
    name            TEXT NOT NULL,
    rtsp_url        TEXT NOT NULL,
    rtsp_transport  TEXT NOT NULL DEFAULT 'tcp',
    host            TEXT,
    username        TEXT,
    password_enc    BYTEA,
    password_nonce  BYTEA,
    codec           codec_kind NOT NULL DEFAULT 'unknown',
    rtsp_sub_url    TEXT,
    use_substream_for_analysis BOOLEAN NOT NULL DEFAULT TRUE,
    substream_codec codec_kind NOT NULL DEFAULT 'h264',
    substream_width INT,
    substream_height INT,
    record_audio    BOOLEAN NOT NULL DEFAULT FALSE,
    analysis_fps    INT NOT NULL DEFAULT 5,
    model_name      TEXT NOT NULL DEFAULT 'yolov8n-320',
    enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    retention_hours INT NOT NULL DEFAULT 168,
    assigned_host   TEXT,
    manual_assign   BOOLEAN NOT NULL DEFAULT FALSE,
    onvif_port              INT,
    mgmt_proto              TEXT NOT NULL DEFAULT 'onvif',
    main_video_encoding     TEXT,
    main_video_width        INT,
    main_video_height       INT,
    main_video_fps          INT,
    main_video_bitrate_kbps INT,
    main_video_gov_length   INT,
    sub_video_encoding      TEXT,
    sub_video_width         INT,
    sub_video_height        INT,
    sub_video_fps           INT,
    sub_video_bitrate_kbps  INT,
    sub_video_gov_length    INT,
    audio_encoding          TEXT,
    audio_bitrate_kbps      INT,
    audio_sample_rate_khz   INT,
    ptz_enabled         BOOLEAN NOT NULL DEFAULT FALSE,
    ptz_profile_token   TEXT,
    ptz_home_preset_id  UUID,
    ptz_idle_timeout_s  INT NOT NULL DEFAULT 30,
    ptz_viewer_control  BOOLEAN NOT NULL DEFAULT FALSE,
    snapshot_interval_sec INT NOT NULL DEFAULT 60,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    FOREIGN KEY (assigned_host) REFERENCES hosts(id) ON DELETE SET NULL
);

CREATE INDEX cameras_assigned_idx ON cameras (assigned_host) WHERE enabled;

CREATE TABLE camera_drift (
    id            UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id     UUID NOT NULL,
    config_name   TEXT NOT NULL,
    field_name    TEXT NOT NULL,
    desired       TEXT NOT NULL,
    observed      TEXT NOT NULL,
    first_seen_at TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    last_seen_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (camera_id, config_name, field_name),
    FOREIGN KEY (camera_id) REFERENCES cameras(id) ON DELETE CASCADE
);

CREATE INDEX camera_drift_camera_idx ON camera_drift (camera_id);

CREATE TABLE segments (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL,
    start_ts        TIMESTAMP WITH TIME ZONE NOT NULL,
    end_ts          TIMESTAMP WITH TIME ZONE NOT NULL,
    host_id         TEXT,
    object_key      TEXT NOT NULL,
    bytes           BIGINT NOT NULL,
    sha256          TEXT NOT NULL,
    has_audio       BOOLEAN NOT NULL DEFAULT FALSE,
    pending_delete_at TIMESTAMP WITH TIME ZONE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    FOREIGN KEY (camera_id) REFERENCES cameras(id) ON DELETE CASCADE,
    FOREIGN KEY (host_id) REFERENCES hosts(id) ON DELETE SET NULL,
    UNIQUE (camera_id, start_ts)
);

CREATE INDEX segments_cam_start_idx ON segments (camera_id, start_ts DESC);

-- Tombstoned rows awaiting verified S3 purge (migration 0006).
CREATE INDEX segments_pending_delete_idx ON segments (pending_delete_at)
    WHERE pending_delete_at IS NOT NULL;

-- Phase 1 audit-fix: admin gate. IHP AuthSupport requires these exact column
-- names: id, email, password_hash, locked_at, failed_login_attempts.
-- Authorization is RBAC via the roles tables below (design_docs/13;
-- users.is_admin was dropped by migration 0018).
-- timezone: IANA name (e.g. Europe/Berlin) for web UI time display;
-- NULL = browser-local client-side fallback (migration 0012).
CREATE TABLE users (
    id                      UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    email                   TEXT NOT NULL UNIQUE,
    password_hash           TEXT NOT NULL,
    locked_at               TIMESTAMP WITH TIME ZONE,
    failed_login_attempts   INT NOT NULL DEFAULT 0,
    last_login_at           TIMESTAMP WITH TIME ZONE,
    timezone                TEXT,
    locale                  TEXT,
    created_at              TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- Phase 4: CV rules (line crossing + zone intrusion). Geometry JSONB:
-- line_cross: { "a": [x,y], "b": [x,y], "direction": "positive"|"negative"|"any" }
-- zone_*:     { "polygon": [[x,y], ...] }   (normalized 0..1 coords)
-- zone_motion adds "min_displacement" (normalized, default 0.03): the
-- track must move at least that far inside the zone to fire.
CREATE TYPE rule_kind AS ENUM ('line_cross', 'zone_enter', 'zone_exit', 'zone_inside', 'zone_motion');

CREATE TABLE rules (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL,
    name            TEXT NOT NULL,
    kind            rule_kind NOT NULL,
    geometry        JSONB NOT NULL,
    classes         INT[] NOT NULL DEFAULT ARRAY[0,1,2,3,5,7],
    cooldown_ms     INT NOT NULL DEFAULT 5000,
    clip_preroll_sec  INT NOT NULL DEFAULT 5,
    clip_postroll_sec INT NOT NULL DEFAULT 5,
    clip_retention_hours INT,
    enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    FOREIGN KEY (camera_id) REFERENCES cameras(id) ON DELETE CASCADE
);

CREATE INDEX rules_camera_idx ON rules (camera_id) WHERE enabled;

CREATE TYPE event_kind AS ENUM
    ('line_crossed', 'zone_enter', 'zone_exit', 'zone_inside', 'zone_motion');

-- The UNIQUE below is duplicate-publish absorption (migration 0014): one
-- analyzer emits at most one event per rule+track per frame ts, so an
-- exact match is a duplicate publish (second EventWriter, redelivery).
CREATE TABLE events (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL,
    rule_id         UUID,
    ts              TIMESTAMP WITH TIME ZONE NOT NULL,
    kind            event_kind NOT NULL,
    class_id        INT,
    track_id        INT,
    confidence      REAL,
    bbox            JSONB,
    thumbnail_key   TEXT,
    segment_ts      TIMESTAMP WITH TIME ZONE,
    host_id         TEXT,
    payload         JSONB,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (camera_id, rule_id, track_id, ts),
    FOREIGN KEY (camera_id) REFERENCES cameras(id) ON DELETE CASCADE,
    FOREIGN KEY (rule_id) REFERENCES rules(id) ON DELETE SET NULL,
    FOREIGN KEY (host_id) REFERENCES hosts(id) ON DELETE SET NULL
);

CREATE INDEX events_cam_ts_idx   ON events (camera_id, ts DESC);
CREATE INDEX events_ts_brin      ON events USING brin (ts);
-- events_track_idx (partial) lives only in migrations/0003-rules-events.sql
-- — IHP's schema-compiler can't parse IS NOT NULL index predicates, and
-- codegen doesn't need it. events_kind_idx was partial there too until
-- 0010-cleanup pruned the dead event_kind values and recreated it plain.

-- Event video clips: assembled node-side from the main fMP4 fragment
-- stream when a rule with clip_retention_hours set fires. retention_hours
-- is snapshotted from the rule at creation. pending_delete_at mirrors the
-- segments tombstone pattern.
CREATE TABLE event_clips (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL,
    rule_id         UUID,
    started_at      TIMESTAMP WITH TIME ZONE NOT NULL,
    duration_sec    INT NOT NULL,
    object_prefix   TEXT NOT NULL,
    retention_hours INT NOT NULL,
    pending_delete_at TIMESTAMP WITH TIME ZONE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    FOREIGN KEY (camera_id) REFERENCES cameras(id) ON DELETE CASCADE,
    FOREIGN KEY (rule_id) REFERENCES rules(id) ON DELETE SET NULL
);

CREATE INDEX event_clips_cam_ts_idx ON event_clips (camera_id, started_at DESC);

CREATE INDEX event_clips_pending_delete_idx ON event_clips (pending_delete_at)
    WHERE pending_delete_at IS NOT NULL;

-- Which events a clip covers (merged clips link multiple events).
CREATE TABLE event_clip_events (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    clip_id     UUID NOT NULL,
    event_id    UUID NOT NULL,
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (clip_id, event_id),
    FOREIGN KEY (clip_id) REFERENCES event_clips(id) ON DELETE CASCADE,
    FOREIGN KEY (event_id) REFERENCES events(id) ON DELETE CASCADE
);

CREATE INDEX event_clip_events_event_idx ON event_clip_events (event_id);

-- Periodic per-camera snapshots for the unified archive timeline
-- (design_docs/12-timeline-archive.md). Produced by the node-side
-- SnapshotWriter from the analysis decode stream; swept with the camera's
-- retention_hours. UNIQUE (camera_id, ts) = idempotent inserts.
CREATE TABLE camera_snapshots (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id   UUID NOT NULL,
    ts          TIMESTAMP WITH TIME ZONE NOT NULL,
    object_key  TEXT NOT NULL,
    bytes       BIGINT NOT NULL,
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (camera_id, ts),
    FOREIGN KEY (camera_id) REFERENCES cameras(id) ON DELETE CASCADE
);

CREATE INDEX camera_snapshots_cam_ts_idx
    ON camera_snapshots (camera_id, ts DESC);

-- Phase 4: admin action audit log.
CREATE TABLE audit_log (
    id              BIGSERIAL PRIMARY KEY,
    user_id         UUID,
    action          TEXT NOT NULL,
    target_type     TEXT NOT NULL,
    target_id       UUID,
    payload         JSONB,
    ts              TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX audit_ts_idx ON audit_log (ts DESC);

-- Phase 5: PTZ presets + per-command audit (migration 0011).
CREATE TABLE ptz_presets (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL,
    name            TEXT NOT NULL,
    onvif_token     TEXT,
    pantilt_x       REAL,
    pantilt_y       REAL,
    zoom            REAL,
    is_home         BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (camera_id, name),
    FOREIGN KEY (camera_id) REFERENCES cameras(id) ON DELETE CASCADE
);

CREATE INDEX ptz_presets_cam_idx ON ptz_presets (camera_id);

ALTER TABLE cameras
    ADD CONSTRAINT cameras_ptz_home_preset_fk
    FOREIGN KEY (ptz_home_preset_id) REFERENCES ptz_presets(id) ON DELETE SET NULL;

CREATE TYPE ptz_source AS ENUM ('web_ui', 'auto_track', 'idle_timeout', 'api', 'schedule');

CREATE TABLE ptz_audit_log (
    id              BIGSERIAL PRIMARY KEY,
    camera_id       UUID NOT NULL,
    user_id         UUID,
    command         TEXT NOT NULL,
    args            JSONB,
    source          ptz_source NOT NULL,
    duration_ms     INT,
    ok              BOOLEAN NOT NULL DEFAULT TRUE,
    error           TEXT,
    ts              TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    FOREIGN KEY (camera_id) REFERENCES cameras(id) ON DELETE CASCADE,
    FOREIGN KEY (user_id) REFERENCES users(id)
);

CREATE INDEX ptz_audit_cam_ts_idx ON ptz_audit_log (camera_id, ts DESC);

-- Roles & ACL (design_docs/13-roles-and-acl.md; runtime DDL is migration
-- 0016-roles-acl.sql — this file is the codegen source). The grant
-- mapping tables (user_roles, role_page_perms, role_camera_perms) keep
-- composite PKs and are deliberately NOT modeled — IHP needs a single
-- `id` PK per table; admin code manages grants with raw SQL.
CREATE TABLE roles (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name        TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    is_system   BOOLEAN NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- admin_audit.id is BIGINT GENERATED ALWAYS AS IDENTITY in migration
-- 0016; BIGSERIAL here is the codegen-parseable spelling (both accept
-- INSERT without id).
CREATE TABLE admin_audit (
    id          BIGSERIAL PRIMARY KEY,
    actor_id    UUID,
    action      TEXT NOT NULL,
    object_kind TEXT NOT NULL,
    object_id   TEXT,
    payload     JSONB,
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    FOREIGN KEY (actor_id) REFERENCES users(id)
);
