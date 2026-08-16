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
    display_name    TEXT NOT NULL,
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
    rtsp_template   TEXT,
    rtsp_transport  TEXT NOT NULL DEFAULT 'tcp',
    host            TEXT,
    port            INT NOT NULL DEFAULT 554,
    username        TEXT,
    password_enc    BYTEA,
    password_nonce  BYTEA,
    codec           codec_kind NOT NULL DEFAULT 'unknown',
    rtsp_sub_url    TEXT,
    rtsp_sub_template TEXT,
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
-- is_admin is HNVR-specific (single admin user for v1; viewer role Phase 6).
CREATE TABLE users (
    id                      UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    email                   TEXT NOT NULL UNIQUE,
    password_hash           TEXT NOT NULL,
    is_admin                BOOLEAN NOT NULL DEFAULT FALSE,
    locked_at               TIMESTAMP WITH TIME ZONE,
    failed_login_attempts   INT NOT NULL DEFAULT 0,
    last_login_at           TIMESTAMP WITH TIME ZONE,
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
    ('line_crossed', 'zone_enter', 'zone_exit', 'zone_inside',
     'zone_motion', 'track_start', 'track_end', 'segment_written', 'system');

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
    FOREIGN KEY (camera_id) REFERENCES cameras(id) ON DELETE CASCADE,
    FOREIGN KEY (rule_id) REFERENCES rules(id) ON DELETE SET NULL,
    FOREIGN KEY (host_id) REFERENCES hosts(id) ON DELETE SET NULL
);

CREATE INDEX events_cam_ts_idx   ON events (camera_id, ts DESC);
CREATE INDEX events_ts_brin      ON events USING brin (ts);
-- Partial indexes events_kind_idx + events_track_idx live only in
-- migrations/0003-rules-events.sql — IHP's schema-compiler can't parse
-- NOT IN / IS NOT NULL index predicates, and codegen doesn't need them.

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
