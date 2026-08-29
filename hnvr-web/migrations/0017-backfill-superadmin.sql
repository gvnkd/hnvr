-- 0017-backfill-superadmin: every users.is_admin = TRUE row gets the
-- seeded superadmin role (design_docs/13 §"Migration & rollout"). Runs
-- before 0018-drop-is-admin in the same boot, so no halfway state can
-- lock out an existing admin.
INSERT INTO user_roles (user_id, role_id)
SELECT id, '00000000-0000-4000-8000-000000000001' FROM users WHERE is_admin
ON CONFLICT DO NOTHING;

NOTIFY roles_events, 'is_admin backfill';
