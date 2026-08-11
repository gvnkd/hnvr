-- HNVR migration 0001 — initial schema (idempotent).
--
-- This is the runtime-migration version of Application/Schema.sql. It
-- uses IF NOT EXISTS / DO-$$ blocks / ALTER-ADD-COLUMN-IF-NOT-EXISTS
-- so it is safe to run against:
--   * a fresh DB (creates everything), AND
--   * a pre-existing DB that was populated by an earlier non-migration
--     workflow (IHP IDE / manual `psql -f Application/Schema.sql` from
--     before M2 landed).
--
-- The migration framework (postgresql-simple-migration) records this
-- script's checksum in `schema_migrations` after a successful run, so
-- it executes exactly once per database. Editing this file after it
-- has been applied to any environment causes a checksum mismatch on
-- the next boot — version-bump to 0002-foo.sql instead.
--
-- Application/Schema.sql stays in sync with this file but uses bare
-- CREATE statements because IHP's schema parser doesn't accept
-- IF NOT EXISTS / DO blocks. Keep both files in sync when changing
-- schema; the duplication is deliberate.

CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE IF NOT EXISTS hosts (
    id              TEXT PRIMARY KEY,
    display_name    TEXT NOT NULL,
    gpu_model       TEXT,
    exec_providers  TEXT[] NOT NULL DEFAULT ARRAY['cpu'],
    is_leader       BOOLEAN NOT NULL DEFAULT FALSE,
    last_health_at  TIMESTAMP WITH TIME ZONE,
    health_json     JSONB,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

-- CREATE TYPE has no IF NOT EXISTS form; wrap in a DO block catching
-- duplicate_object. The enum values are immutable once any row uses
-- them, so this block never mutates an existing type.
DO $$ BEGIN
    CREATE TYPE codec_kind AS ENUM ('h264', 'hevc', 'unknown');
EXCEPTION WHEN duplicate_object THEN null;
END $$;

CREATE TABLE IF NOT EXISTS cameras (
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
    enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    retention_days  INT NOT NULL DEFAULT 7,
    assigned_host   TEXT,
    manual_assign   BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    FOREIGN KEY (assigned_host) REFERENCES hosts(id) ON DELETE SET NULL
);

CREATE INDEX IF NOT EXISTS cameras_assigned_idx ON cameras (assigned_host) WHERE enabled;

-- Backfill rtsp_transport on pre-existing cameras rows (column added
-- Aug 11 2026 with M1; Sergey's dev DB had cameras without it). On a
-- fresh DB the CREATE TABLE above already includes the column, so this
-- ALTER is a no-op. Postgres supports ADD COLUMN IF NOT EXISTS since 9.6.
ALTER TABLE cameras ADD COLUMN IF NOT EXISTS rtsp_transport TEXT NOT NULL DEFAULT 'tcp';

CREATE TABLE IF NOT EXISTS segments (
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

CREATE INDEX IF NOT EXISTS segments_cam_start_idx ON segments (camera_id, start_ts DESC);

-- BRIN index on start_ts for retention-sweep range scans (M6). BRIN is
-- essentially free on naturally time-ordered inserts (~17 M rows/year
-- per camera at 1 segment/sec). Without it the sweeper's
-- `WHERE end_ts < NOW() - INTERVAL '<n> days'` falls back to a seq
-- scan that grows linearly with table size.
CREATE INDEX IF NOT EXISTS segments_start_ts_brin ON segments USING brin (start_ts);

-- Phase 1 audit-fix: admin gate. IHP AuthSupport requires these exact
-- column names: id, email, password_hash, locked_at, failed_login_attempts.
-- is_admin is HNVR-specific (single admin user for v1; viewer role Phase 6).
CREATE TABLE IF NOT EXISTS users (
    id                      UUID DEFAULT uuid_generate_v4() PRIMARY KEY,
    email                   TEXT NOT NULL UNIQUE,
    password_hash           TEXT NOT NULL,
    is_admin                BOOLEAN NOT NULL DEFAULT FALSE,
    locked_at               TIMESTAMP WITH TIME ZONE,
    failed_login_attempts   INT NOT NULL DEFAULT 0,
    last_login_at           TIMESTAMP WITH TIME ZONE,
    created_at              TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
