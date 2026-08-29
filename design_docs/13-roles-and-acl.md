# HNVR — Roles, ACLs & Admin Service

Post-v1 replacement for the `users.is_admin` boolean (see 06-data-model.md).
Two deliverables:

1. **RBAC + per-camera ACL** enforced server-side in the end-user app (hnvr-leader IHP).
2. **hnvr-admin** — a dedicated service (own binary, own network interface) that owns
   all management mutation: roles, users, role assignment, camera CRUD/config.

The end-user app becomes read-mostly: live view, PTZ (if permitted), archive
playback/purge (if permitted), events. All writes that change topology or policy
live behind the admin service.

## Principles

- **Default-deny.** No matching permission row ⇒ no access, no UI element, no route.
- **Union semantics.** A user's effective permission set is the union over all
  assigned roles. No role hierarchy, no deny rules (v1).
- **Hide, don't 403 — but enforce anyway.** If a role lacks a permission the object
  is not rendered at all; the controller still checks, because UI hiding is cosmetic.
- **Filter in SQL.** Camera lists join against the effective ACL so counts and
  pagination never leak the existence of hidden cameras.
- **Pure authorization core.** All decisions in `Hnvr.Core.Authz` (pure, cabal-testable;
  pitfall #14). Web layers project IHP records into the pure types at the call site.
- **ACLs are a web/API concern only.** The NATS snapshot path and node config flow
  are untouched — nodes receive full camera config regardless of roles.

## Schema

```sql
-- =========================================================
-- Roles & ACL
-- =========================================================
CREATE TYPE camera_action AS ENUM (
    'view_live',        -- WHEP live stream + live page
    'view_config',      -- read camera detail/config
    'edit_config',      -- update config incl. enable/disable
    'delete_camera',
    'ptz_move',         -- continuous move / zoom / focus
    'ptz_preset',       -- preset recall, set-home, autotrack toggle
    'view_archive',     -- timeline, playlists, segment download
    'purge_archive',    -- destructive retention/purge of recordings
    'manage_events'     -- acknowledge/delete events, edit rules
);

CREATE TYPE page_kind AS ENUM (
    'dashboard', 'live', 'archive', 'events', 'rules', 'hosts', 'settings'
);

CREATE TABLE roles (
    id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name        TEXT NOT NULL UNIQUE,                -- 'operator', 'guard-night'
    description TEXT NOT NULL DEFAULT '',
    is_system   BOOLEAN NOT NULL DEFAULT FALSE,      -- superadmin/guest: not editable
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);

CREATE TABLE user_roles (
    user_id UUID NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    role_id UUID NOT NULL REFERENCES roles (id) ON DELETE CASCADE,
    PRIMARY KEY (user_id, role_id)
);

-- Global per-page grants.
CREATE TABLE role_page_perms (
    role_id UUID NOT NULL REFERENCES roles (id) ON DELETE CASCADE,
    page    page_kind NOT NULL,
    PRIMARY KEY (role_id, page)
);

-- Per-camera grants. camera_id NULL = wildcard default ACL for the role;
-- a row with a concrete camera_id overrides the wildcard for that
-- (role, camera, action).
CREATE TABLE role_camera_perms (
    role_id   UUID NOT NULL REFERENCES roles (id) ON DELETE CASCADE,
    camera_id UUID REFERENCES cameras (id) ON DELETE CASCADE,   -- NULL = all cameras
    action    camera_action NOT NULL,
    UNIQUE (role_id, camera_id, action)
);

-- Every admin-service mutation lands here (mirrors the PTZ audit pattern).
CREATE TABLE admin_audit (
    id          BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    actor_id    UUID REFERENCES users (id),
    action      TEXT NOT NULL,                       -- 'role.update', 'camera.delete', ...
    object_kind TEXT NOT NULL,                       -- 'role' | 'user' | 'camera'
    object_id   TEXT,
    payload     JSONB,                               -- before/after diff
    created_at  TIMESTAMP WITH TIME ZONE NOT NULL DEFAULT NOW()
);
```

Notes:

- `camera_action` as a PG enum (not boolean columns) — new actions are an enum
  extension, not a column migration. Destructive actions (`delete_camera`,
  `purge_archive`) always get their own action, never implied by `edit_config`.
- PTZ is split `ptz_move` / `ptz_preset` — a guard may need presets without
  free move, and autotrack toggling is preset-class.
- `is_system` roles: `superadmin` (all grants, seeded) and optionally `guest`
  (see Anonymous below). System roles are immutable via the admin UI.

## Pure authorization core

`hnvr-core/src/Hnvr/Core/Authz.hs` — no IO, no IHP types:

```haskell
data RoleSet = RoleSet
  { rsPages       :: Set PageKind
  , rsCamWildcard :: Set CameraAction              -- camera_id NULL rows
  , rsCamPer      :: Map CameraId (Set CameraAction)
  }

emptyRoleSet :: RoleSet

-- per-camera rows override the wildcard for that camera
cameraAllowed :: RoleSet -> CameraAction -> CameraId -> Bool
pageAllowed   :: RoleSet -> PageKind -> Bool

-- SQL projection used by BOTH services (single source of truth)
roleSetQuery :: Query  -- UNION over user's roles, grouped
```

Property tests (hnvr-core test suite): default-deny, union monotonicity
(adding a role never removes a grant), override-beats-wildcard, wildcard
covers unknown camera ids.

## Enforcement in the end-user app

- One role-set fetch per request, cached in the request context alongside
  `currentUser` (same shape as `ensureIsUser`, pitfall #53):

```haskell
ensurePerm :: (?context :: ControllerContext) => CameraAction -> CameraId -> IO ()
ensurePagePerm :: (?context :: ControllerContext) => PageKind -> IO ()
```

- Camera-listing controllers (`Dashboard`, `Cameras` index, `Events` filter
  options, `Archive` picker) filter with a SQL `WHERE id IN (
  SELECT camera id FROM effective_acl …)` — never post-filter in Haskell.
- Views receive the `RoleSet` implicitly; nav items, PTZ markup, purge buttons
  and config links are rendered only when the matching grant exists
  (same discipline as today's anonymous-PTZ hiding).
- `/whep/<slug>` middleware checks `view_live` before proxying to MediaMTX —
  the stream endpoint is part of the ACL boundary, not just the page.
- Role changes invalidate via PG `LISTEN/NOTIFY` on a dedicated pg-simple
  connection (pattern exists, pitfall #41); cache TTL 30 s as backstop.

### Anonymous access

Today dashboard + `/ShowLive` are anonymous-readable. With roles, anonymous is
modeled as an optional built-in `guest` role (is_system, no user row):
requests with no session resolve to the guest `RoleSet`. Setting no grants on
`guest` restores full login-wall behaviour without code changes.

## hnvr-admin service

- Separate binary `hnvr-admin` (same hnvr-web IHP app family, own cabal
  executable), own port (dev `18010`, behind `HNVR_ADMIN_PORT`) bound to a
  dedicated interface: `HNVR_ADMIN_LISTEN=127.0.0.1` or a mgmt VLAN address.
  Never exposed on the end-user interface; firewall/NixOS module enforces it.
- Own session cookie name/path — an end-user session grants nothing here.
- Owns: roles CRUD, user CRUD + role assignment, camera create/edit/enable/
  disable/delete, retention policy, host management. End-user app loses those
  controllers entirely (routes removed, not just hidden).
- Shares the DB and the `Hnvr.Core.Authz` / `roleSetQuery` — one policy, two
  front doors. Admin mutations also re-broadcast the camera snapshot over NATS
  exactly as today's Cameras controller does (ConfigBroadcaster path unchanged).
- Every mutation writes `admin_audit` (actor, action, diff).

### Bootstrap & lockout protection

- First run: seeded `superadmin` role + `hnvr-admin create-user --email …`
  CLI (or `INITIAL_ADMIN_EMAIL`/`INITIAL_ADMIN_PASSWORD` env, same pattern as
  05-web-and-live-view.md). No chicken-and-egg via UI.
- The service refuses to delete the last user holding `superadmin`, to delete
  the `superadmin` role, or to remove your own last superadmin grant.

## Migration & rollout

1. Migration `00NN-roles-acl.sql`: enum + tables above; seed `superadmin`
   (all page kinds, wildcard all camera actions) and `guest` (dashboard +
   live page, wildcard `view_live` — preserves current anonymous behaviour).
2. Backfill: every `users.is_admin = TRUE` row gets `superadmin`;
   `is_admin` column dropped in a FOLLOW-UP migration after soak.
3. e2e leader (:18002) gets `HNVR_DISABLE_AUTHZ=1` gate (pattern of the other
   `HNVR_DISABLE_*` role gates) OR seeded fixtures granting everything —
   otherwise all 35 Playwright specs break.
4. Move camera/rule/host mutation controllers to hnvr-admin; delete routes
   from the end-user FrontController; nav links to admin live only in
   hnvr-admin's layout.
5. e2e additions: hidden-camera absence (DOM + API + WHEP 404), PTZ hidden
   without `ptz_move`, purge 403 without `purge_archive`, admin-service
   role edit takes effect after cache invalidation.

## Explicitly out of scope (v1)

- Role hierarchy / deny rules / time-bound grants.
- Per-event or per-recording ACLs (camera granularity only).
- SSO/OIDC — local users only.
- Row-level security in Postgres — policy lives in `Hnvr.Core.Authz`, RLS
  would duplicate it and fight IHP's connection pooling.
