-- 0013-camera-snapshots: periodic snapshot store for the unified archive
-- timeline (design_docs/12-timeline-archive.md, Phase A).
--
-- Node-side SnapshotWriter taps the analysis decode pipeline and uploads a
-- JPEG per camera every cameras.snapshot_interval_sec to
-- <slug>/snapshots/<YYYY-MM-DD>/<HH-MM-SS.mmm>.jpg; the leader-side writer
-- inserts one row per upload. 0 = snapshots disabled for the camera.
-- Rows are swept with the camera's retention_hours by RetentionSweeper.
-- UNIQUE (camera_id, ts) makes republished SnapshotWritten messages
-- idempotent (same pattern as segments.(camera_id, start_ts)).

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

ALTER TABLE cameras
    ADD COLUMN snapshot_interval_sec INT NOT NULL DEFAULT 60;
