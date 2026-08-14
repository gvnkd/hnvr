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
    retention_days  INT NOT NULL DEFAULT 7,
    assigned_host   TEXT,
    manual_assign   BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    FOREIGN KEY (assigned_host) REFERENCES hosts(id) ON DELETE SET NULL
);

CREATE INDEX cameras_assigned_idx ON cameras (assigned_host) WHERE enabled;

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
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    FOREIGN KEY (camera_id) REFERENCES cameras(id) ON DELETE CASCADE,
    FOREIGN KEY (host_id) REFERENCES hosts(id) ON DELETE SET NULL,
    UNIQUE (camera_id, start_ts)
);

CREATE INDEX segments_cam_start_idx ON segments (camera_id, start_ts DESC);

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
CREATE TYPE rule_kind AS ENUM ('line_cross', 'zone_enter', 'zone_exit', 'zone_inside');

CREATE TABLE rules (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL,
    name            TEXT NOT NULL,
    kind            rule_kind NOT NULL,
    geometry        JSONB NOT NULL,
    classes         INT[] NOT NULL DEFAULT ARRAY[0,1,2,3,5,7],
    cooldown_ms     INT NOT NULL DEFAULT 5000,
    enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    FOREIGN KEY (camera_id) REFERENCES cameras(id) ON DELETE CASCADE
);

CREATE INDEX rules_camera_idx ON rules (camera_id) WHERE enabled;

CREATE TYPE event_kind AS ENUM
    ('line_crossed', 'zone_enter', 'zone_exit', 'zone_inside',
     'track_start', 'track_end', 'segment_written', 'system');

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
