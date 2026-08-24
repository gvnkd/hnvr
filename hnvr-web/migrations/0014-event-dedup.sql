-- 0014-event-dedup: absorb duplicate CV events at the DB level.
--
-- Symptom (Aug 21 2026): event rows appearing in identical pairs —
-- same camera, rule, track, µs-exact ts, confidence. Root cause: TWO
-- leader processes with a live EventWriter each (a stray/test leader
-- alongside the real one — both share the dev DB + NATS), each
-- draining hnvr.events and inserting. Sub-ms created_at deltas prove
-- concurrent inserters; the per-(rule,track) rule cooldown in the
-- analyzer was never the failing layer. segments /
-- camera_snapshots / event_clips already absorb duplicate publishes
-- with ON CONFLICT — events was the odd ingest table out.
--
-- UNIQUE (camera_id, rule_id, track_id, ts): one analyzer emits at
-- most one event per rule+track per frame timestamp, so an exact
-- match is definitionally a duplicate publish. Rows with NULL
-- rule_id/track_id never conflict (PG NULL semantics); the CvEvent
-- insert path always sets both.
--
-- The dedup pass below keeps the earliest-created row per group and
-- re-points event_clip_events links before deleting the rest. Plain
-- TEMP TABLE (no ON COMMIT DROP) so the script also works under
-- psql's per-statement autocommit.

DROP TABLE IF EXISTS events_dedup_map;
CREATE TEMP TABLE events_dedup_map AS
SELECT id,
       FIRST_VALUE(id) OVER (
         PARTITION BY camera_id, rule_id, track_id, ts
         ORDER BY created_at ASC, id ASC
       ) AS keep_id
FROM events
WHERE rule_id IS NOT NULL AND track_id IS NOT NULL;

-- Move clip links from sacrificial rows to the keeper. The ClipReady
-- linker matches every event in its window, so both rows of a pair
-- may already link the same clip — ON CONFLICT absorbs that.
INSERT INTO event_clip_events (clip_id, event_id, created_at)
SELECT ece.clip_id, m.keep_id, NOW()
FROM event_clip_events ece
JOIN events_dedup_map m ON m.id = ece.event_id
WHERE m.keep_id <> m.id
ON CONFLICT (clip_id, event_id) DO NOTHING;

DELETE FROM event_clip_events ece
USING events_dedup_map m
WHERE ece.event_id = m.id AND m.keep_id <> m.id;

DELETE FROM events e
USING events_dedup_map m
WHERE e.id = m.id AND m.keep_id <> m.id;

-- Idempotent so a manual application ahead of the leader boot replay
-- doesn't fail the boot migration. ADD CONSTRAINT names its backing
-- index after the constraint, so an existing constraint raises
-- duplicate_table (42P07), not duplicate_object (42710) — catch both.
DO $$
BEGIN
    ALTER TABLE events
        ADD CONSTRAINT events_camera_id_rule_id_track_id_ts_key
        UNIQUE (camera_id, rule_id, track_id, ts);
EXCEPTION WHEN duplicate_object OR duplicate_table THEN NULL;
END $$;
