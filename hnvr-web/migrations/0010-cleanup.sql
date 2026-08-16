-- 0010-cleanup.sql — dead schema cleanup (Aug 2026 stub/dead-field audit).
--
-- Drops columns that were never read by any logic (or never written):
--   * cameras.rtsp_template / rtsp_sub_template — no form inputs ever
--     existed; the fill lists wiped them to NULL on every Save.
--   * cameras.port — display-only vestige; ONVIF uses onvif_port, RTSP
--     connect uses the rtsp_url authority.
--   * hosts.display_name — written as a copy of the host id, never read
--     (views render hosts.id).
--
-- Prunes event_kind values with zero emitters (track_start, track_end,
-- segment_written, system). PG has no ALTER TYPE ... DROP VALUE, so the
-- type is recreated. events_kind_idx's predicate referenced two of the
-- dead values; it becomes a plain (kind, ts) index.

ALTER TABLE cameras DROP COLUMN IF EXISTS rtsp_template;
ALTER TABLE cameras DROP COLUMN IF EXISTS rtsp_sub_template;
ALTER TABLE cameras DROP COLUMN IF EXISTS port;
ALTER TABLE hosts DROP COLUMN IF EXISTS display_name;

DROP INDEX IF EXISTS events_kind_idx;
ALTER TABLE events ALTER COLUMN kind TYPE TEXT;
DROP TYPE IF EXISTS event_kind;
CREATE TYPE event_kind AS ENUM
    ('line_crossed', 'zone_enter', 'zone_exit', 'zone_inside', 'zone_motion');
ALTER TABLE events ALTER COLUMN kind TYPE event_kind USING kind::event_kind;
CREATE INDEX IF NOT EXISTS events_kind_idx ON events (kind, ts DESC);
