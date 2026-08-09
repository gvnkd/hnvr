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
-- IMPORTANT: IHP schema parser does not accept comments INSIDE CREATE
-- TABLE bodies. Keep column docs in the module Haddocks or in design_docs.

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
    host            INET,
    port            INT NOT NULL DEFAULT 554,
    username        TEXT,
    password        TEXT,
    codec           codec_kind NOT NULL DEFAULT 'unknown',
    rtsp_sub_url    TEXT,
    rtsp_sub_template TEXT,
    use_substream_for_analysis BOOLEAN NOT NULL DEFAULT TRUE,
    substream_codec codec_kind NOT NULL DEFAULT 'h264',
    substream_width INT,
    substream_height INT,
    record_audio    BOOLEAN NOT NULL DEFAULT FALSE,
    analysis_fps    INT NOT NULL DEFAULT 5,
    enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    retention_days  INT NOT NULL DEFAULT 7,
    assigned_host   TEXT,
    manual_assign   BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    FOREIGN KEY (assigned_host) REFERENCES hosts(id) ON DELETE SET NULL
);

CREATE INDEX cameras_assigned_idx ON cameras (assigned_host) WHERE enabled;

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
