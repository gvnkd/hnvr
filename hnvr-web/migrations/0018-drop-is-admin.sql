-- 0018-drop-is-admin: the RBAC tables (0016) + backfill (0017) replace
-- the boolean. Role resolution stopped reading it in 0.22.0.0.
ALTER TABLE users DROP COLUMN IF EXISTS is_admin;
