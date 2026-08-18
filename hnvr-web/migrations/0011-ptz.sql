-- 0011-ptz.sql — Phase 5: manual PTZ control + presets.
-- Design: design_docs/06-data-model.md ("PTZ presets", "PTZ audit
-- log"), 08 Phase 5.
--
-- Deviations from design 06: no ptz_onvif_url / ptz_username /
-- ptz_password_enc columns — the PTZ service XAddr is discovered at
-- runtime via GetCapabilities (same pattern as the media XAddr in
-- Hnvr.Web.OnvifSync) and ONVIF reuses the camera's own credentials.
-- ptz_audit_log gains ok/error columns: the row records EXECUTION on
-- the owning host (via hnvr.ptz.audit), not publish intent.

ALTER TABLE cameras ADD COLUMN IF NOT EXISTS ptz_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE cameras ADD COLUMN IF NOT EXISTS ptz_profile_token TEXT;
ALTER TABLE cameras ADD COLUMN IF NOT EXISTS ptz_home_preset_id UUID;
ALTER TABLE cameras ADD COLUMN IF NOT EXISTS ptz_idle_timeout_s INT NOT NULL DEFAULT 30
    CHECK (ptz_idle_timeout_s BETWEEN 0 AND 3600);
ALTER TABLE cameras ADD COLUMN IF NOT EXISTS ptz_viewer_control BOOLEAN NOT NULL DEFAULT FALSE;

CREATE TABLE IF NOT EXISTS ptz_presets (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    onvif_token     TEXT,
    pantilt_x       REAL,
    pantilt_y       REAL,
    zoom            REAL,
    is_home         BOOLEAN NOT NULL DEFAULT FALSE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (camera_id, name)
);
CREATE INDEX IF NOT EXISTS ptz_presets_cam_idx ON ptz_presets (camera_id);

DO $$ BEGIN
    ALTER TABLE cameras
        ADD CONSTRAINT cameras_ptz_home_preset_fk
        FOREIGN KEY (ptz_home_preset_id) REFERENCES ptz_presets(id) ON DELETE SET NULL;
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE ptz_source AS ENUM ('web_ui', 'auto_track', 'idle_timeout', 'api', 'schedule');
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS ptz_audit_log (
    id              BIGSERIAL PRIMARY KEY,
    camera_id       UUID NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    user_id         UUID REFERENCES users(id),
    command         TEXT NOT NULL,
    args            JSONB,
    source          ptz_source NOT NULL,
    duration_ms     INT,
    ok              BOOLEAN NOT NULL DEFAULT TRUE,
    error           TEXT,
    ts              TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS ptz_audit_cam_ts_idx ON ptz_audit_log (camera_id, ts DESC);
