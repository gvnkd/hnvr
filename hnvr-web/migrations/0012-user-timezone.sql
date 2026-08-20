-- 0012-user-timezone.sql — per-user IANA timezone for web UI time
-- display. NULL = browser-local (client-side fallback).

ALTER TABLE users ADD COLUMN IF NOT EXISTS timezone TEXT;
