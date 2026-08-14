-- 0005-zone-motion.sql — Phase 4 follow-up: zone_motion rule kind.
-- Fires only when a track accumulates >= min_displacement movement
-- inside the polygon (geometry JSONB: {"polygon": [...],
-- "min_displacement": 0.03}). Stationary objects never trigger it.

ALTER TYPE rule_kind ADD VALUE IF NOT EXISTS 'zone_motion';
ALTER TYPE event_kind ADD VALUE IF NOT EXISTS 'zone_motion';
