-- 0007-event-clips.sql — separated event video store.
--
-- 1. cameras.retention_days → retention_hours (backfilled *24). The
--    RetentionSweeper switches to INTERVAL '1 hour' granularity.
-- 2. rules gain per-rule clip config: clip_preroll_sec / clip_postroll_sec
--    bound the clip window around a firing event; clip_retention_hours
--    NULL means clip recording is OFF for that rule.
-- 3. event_clips: one row per assembled clip (fMP4 init + fragments under
--    object_prefix, e.g. <slug>/clips/<YYYY-MM-DD/HH-MM-SS.mmm>/).
--    retention_hours is snapshotted from the rule at clip creation so
--    later rule edits don't retro-change existing clips.
--    pending_delete_at mirrors the segments tombstone pattern (0006).
-- 4. event_clip_events: which events a clip covers (merged clips link
--    multiple events).

ALTER TABLE cameras
    ADD COLUMN IF NOT EXISTS retention_hours INT;

UPDATE cameras
   SET retention_hours = retention_days * 24
 WHERE retention_hours IS NULL;

ALTER TABLE cameras
    ALTER COLUMN retention_hours SET NOT NULL,
    ALTER COLUMN retention_hours SET DEFAULT 168;

ALTER TABLE cameras
    DROP COLUMN IF EXISTS retention_days;

ALTER TABLE rules
    ADD COLUMN IF NOT EXISTS clip_preroll_sec INT NOT NULL DEFAULT 5,
    ADD COLUMN IF NOT EXISTS clip_postroll_sec INT NOT NULL DEFAULT 5,
    ADD COLUMN IF NOT EXISTS clip_retention_hours INT;

CREATE TABLE IF NOT EXISTS event_clips (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    rule_id         UUID REFERENCES rules(id) ON DELETE SET NULL,
    started_at      TIMESTAMP WITH TIME ZONE NOT NULL,
    duration_sec    INT NOT NULL,
    object_prefix   TEXT NOT NULL,
    retention_hours INT NOT NULL,
    pending_delete_at TIMESTAMP WITH TIME ZONE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS event_clips_cam_ts_idx
    ON event_clips (camera_id, started_at DESC);

CREATE INDEX IF NOT EXISTS event_clips_pending_delete_idx
    ON event_clips (pending_delete_at)
    WHERE pending_delete_at IS NOT NULL;

CREATE TABLE IF NOT EXISTS event_clip_events (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    clip_id     UUID NOT NULL REFERENCES event_clips(id) ON DELETE CASCADE,
    event_id    UUID NOT NULL REFERENCES events(id) ON DELETE CASCADE,
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    UNIQUE (clip_id, event_id)
);

CREATE INDEX IF NOT EXISTS event_clip_events_event_idx
    ON event_clip_events (event_id);
