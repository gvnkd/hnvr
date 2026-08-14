-- 0003-rules-events.sql — Phase 4: CV rules + events tables.
-- Idempotent guards so it applies cleanly on fresh + existing DBs.
-- Design: design_docs/06-data-model.md ("Rules", "Events" sections).

-- idempotent enum creation for re-runnable deploys
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'rule_kind') THEN
        CREATE TYPE rule_kind AS ENUM ('line_cross', 'zone_enter', 'zone_exit', 'zone_inside');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'event_kind') THEN
        CREATE TYPE event_kind AS ENUM
            ('line_crossed', 'zone_enter', 'zone_exit', 'zone_inside',
             'track_start', 'track_end',
             'segment_written',
             'system');
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS rules (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    name            TEXT NOT NULL,
    kind            rule_kind NOT NULL,
    -- line_cross: { "a": [x,y], "b": [x,y], "direction": "positive"|"negative"|"any" }
    -- zone_*:     { "polygon": [[x,y], ...] }   (normalized 0..1 coords)
    geometry        JSONB NOT NULL,
    classes         INT[] NOT NULL DEFAULT ARRAY[0,1,2,3,5,7],
    cooldown_ms     INT NOT NULL DEFAULT 5000,
    enabled         BOOLEAN NOT NULL DEFAULT TRUE,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS rules_camera_idx ON rules (camera_id) WHERE enabled;

CREATE TABLE IF NOT EXISTS events (
    id              UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    camera_id       UUID NOT NULL REFERENCES cameras(id) ON DELETE CASCADE,
    rule_id         UUID REFERENCES rules(id) ON DELETE SET NULL,
    ts              TIMESTAMP WITH TIME ZONE NOT NULL,
    kind            event_kind NOT NULL,
    class_id        INT,
    track_id        INT,
    confidence      REAL,
    bbox            JSONB,
    thumbnail_key   TEXT,
    segment_ts      TIMESTAMP WITH TIME ZONE,
    host_id         TEXT REFERENCES hosts(id) ON DELETE SET NULL,
    payload         JSONB,
    created_at      TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS events_cam_ts_idx   ON events (camera_id, ts DESC);
CREATE INDEX IF NOT EXISTS events_ts_brin      ON events USING brin (ts);
CREATE INDEX IF NOT EXISTS events_kind_idx     ON events (kind, ts DESC)
    WHERE kind NOT IN ('system', 'segment_written');
CREATE INDEX IF NOT EXISTS events_track_idx    ON events (camera_id, track_id, ts DESC)
    WHERE track_id IS NOT NULL;
