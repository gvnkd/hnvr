-- 0016-roles-acl.sql — Roles & ACL schema (design_docs/13-roles-and-acl.md,
-- milestone M1). Post-v1 replacement for users.is_admin (the column stays
-- honored as a fallback until M5 backfills and drops it).
--
-- Ships the full design schema including admin_audit (written only by the
-- hnvr-admin service in M3) so the RBAC surface lands atomically.
--
-- Seed roles use well-known UUIDs so the seed is idempotent and code can
-- refer to them without a lookup:
--   superadmin = 00000000-0000-4000-8000-000000000001
--   guest      = 00000000-0000-4000-8000-000000000002 (anonymous requests)

DO $$ BEGIN
    CREATE TYPE camera_action AS ENUM (
        'view_live',
        'view_config',
        'edit_config',
        'delete_camera',
        'ptz_move',
        'ptz_preset',
        'view_archive',
        'purge_archive',
        'manage_events'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

DO $$ BEGIN
    CREATE TYPE page_kind AS ENUM (
        'dashboard', 'live', 'archive', 'events', 'rules', 'hosts', 'settings'
    );
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS roles (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name        TEXT NOT NULL UNIQUE,
    description TEXT NOT NULL DEFAULT '',
    is_system   BOOLEAN NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS user_roles (
    user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role_id UUID NOT NULL REFERENCES roles (id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, role_id)
);

CREATE TABLE IF NOT EXISTS role_page_perms (
    role_id UUID NOT NULL REFERENCES roles (id) ON DELETE CASCADE,
    page    page_kind NOT NULL,
    PRIMARY KEY (role_id, page)
);

-- camera_id NULL = wildcard default ACL for the role; a concrete camera_id
-- row overrides the wildcard for that (role, camera, action). NOTE: NULL
-- camera_id rows are not deduplicated by the UNIQUE constraint (NULLs are
-- distinct) — writers must guard wildcard inserts with NOT EXISTS.
CREATE TABLE IF NOT EXISTS role_camera_perms (
    role_id   UUID NOT NULL REFERENCES roles (id) ON DELETE CASCADE,
    camera_id UUID REFERENCES cameras (id) ON DELETE CASCADE,
    action    camera_action NOT NULL,
    UNIQUE (role_id, camera_id, action)
);
CREATE INDEX IF NOT EXISTS role_camera_perms_cam_idx ON role_camera_perms (camera_id);

-- Every admin-service mutation lands here (mirrors the ptz_audit_log
-- pattern). Written from M3 onward.
CREATE TABLE IF NOT EXISTS admin_audit (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor_id    UUID REFERENCES users (id),
    action      TEXT NOT NULL,
    object_kind TEXT NOT NULL,
    object_id   TEXT,
    payload     JSONB,
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS admin_audit_ts_idx ON admin_audit (created_at DESC);

-- ---- Seed: superadmin (all grants) + guest (current anonymous behaviour)

INSERT INTO roles (id, name, description, is_system) VALUES
    ('00000000-0000-4000-8000-000000000001', 'superadmin', 'Full access to every page and camera action', TRUE),
    ('00000000-0000-4000-8000-000000000002', 'guest', 'Anonymous (unauthenticated) requests', TRUE)
ON CONFLICT (name) DO NOTHING;

INSERT INTO role_page_perms (role_id, page)
SELECT '00000000-0000-4000-8000-000000000001', p
FROM unnest(enum_range(NULL::page_kind)) AS p
ON CONFLICT DO NOTHING;

INSERT INTO role_camera_perms (role_id, camera_id, action)
SELECT '00000000-0000-4000-8000-000000000001', NULL, a
FROM unnest(enum_range(NULL::camera_action)) AS a
WHERE NOT EXISTS (
    SELECT 1 FROM role_camera_perms
    WHERE role_id = '00000000-0000-4000-8000-000000000001'
      AND camera_id IS NULL AND action = a
);

INSERT INTO role_page_perms (role_id, page)
SELECT '00000000-0000-4000-8000-000000000002', p
FROM (VALUES ('dashboard'::page_kind), ('live'::page_kind)) AS v (p)
ON CONFLICT DO NOTHING;

INSERT INTO role_camera_perms (role_id, camera_id, action)
SELECT '00000000-0000-4000-8000-000000000002', NULL, 'view_live'
WHERE NOT EXISTS (
    SELECT 1 FROM role_camera_perms
    WHERE role_id = '00000000-0000-4000-8000-000000000002'
      AND camera_id IS NULL AND action = 'view_live'
);
