-- 0019-guest-ordinary-role: the guest role (anonymous requests) is no
-- longer is_system — it is editable/deletable in hnvr-admin like any
-- other role (Sergey, 2026-08-30). Deleting it = full login wall;
-- `hnvr-admin enable-guest` re-creates the well-known row. superadmin
-- stays system.
UPDATE roles SET is_system = FALSE
WHERE id = '00000000-0000-4000-8000-000000000002' AND name = 'guest';

NOTIFY roles_events, 'guest role unprotected';
