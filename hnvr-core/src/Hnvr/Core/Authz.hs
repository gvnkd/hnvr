{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure authorization core for roles & ACLs
-- (design_docs/13-roles-and-acl.md).
--
-- No IO, no IHP types (pitfall #14) — web layers project SQL rows into
-- 'RoleSet' via 'buildRoleSet' and ask 'cameraAllowed' \/ 'pageAllowed'.
--
-- Semantics:
--
--   * __Default-deny__ — nothing in the 'RoleSet', no access.
--   * __Union__ — a user's effective set is the union over all assigned
--     roles ('Semigroup' instance; no hierarchy, no deny rules).
--   * __Override__ — a per-camera grant row replaces the wildcard set
--     for that camera entirely (it does not add to it).
module Hnvr.Core.Authz
  ( CameraAction (..),
    PageKind (..),
    RoleSet (..),
    emptyRoleSet,
    cameraAllowed,
    pageAllowed,
    buildRoleSet,
    roleSetQuery,
    allCameraActions,
    allPageKinds,
    cameraActionToText,
    cameraActionFromText,
    pageKindToText,
    pageKindFromText,
    superadminRoleId,
    guestRoleId,
  )
where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Hnvr.Core.Id (CameraId)

-- | Per-camera actions, mirroring the @camera_action@ PG enum.
data CameraAction
  = ViewLive
  | ViewConfig
  | EditConfig
  | DeleteCamera
  | PtzMove
  | PtzPreset
  | ViewArchive
  | PurgeArchive
  | ManageEvents
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Top-level pages, mirroring the @page_kind@ PG enum.
data PageKind
  = PageDashboard
  | PageLive
  | PageArchive
  | PageEvents
  | PageRules
  | PageHosts
  | PageSettings
  deriving stock (Eq, Ord, Show, Enum, Bounded)

allCameraActions :: [CameraAction]
allCameraActions = [minBound .. maxBound]

allPageKinds :: [PageKind]
allPageKinds = [minBound .. maxBound]

-- | A user's effective permission set: the union over all assigned roles.
data RoleSet = RoleSet
  { -- | Granted pages.
    rsPages :: Set PageKind,
    -- | Wildcard grants (@camera_id NULL@ rows) applied to every camera
    -- without a per-camera override.
    rsCamWildcard :: Set CameraAction,
    -- | Per-camera overrides; presence of a key replaces the wildcard
    -- for that camera.
    rsCamPer :: Map CameraId (Set CameraAction)
  }
  deriving stock (Eq, Show)

instance Semigroup RoleSet where
  RoleSet p1 w1 c1 <> RoleSet p2 w2 c2 =
    RoleSet (p1 <> p2) (w1 <> w2) (Map.unionWith (<>) c1 c2)

instance Monoid RoleSet where
  mempty = emptyRoleSet

emptyRoleSet :: RoleSet
emptyRoleSet = RoleSet Set.empty Set.empty Map.empty

-- | Default-deny with per-camera override: a camera with an override row
-- uses ONLY that row's action set; all other cameras fall back to the
-- wildcard.
cameraAllowed :: RoleSet -> CameraAction -> CameraId -> Bool
cameraAllowed rs action cam =
  Set.member action (Map.findWithDefault (rsCamWildcard rs) cam (rsCamPer rs))

pageAllowed :: RoleSet -> PageKind -> Bool
pageAllowed rs page = Set.member page (rsPages rs)

-- | Fold 'roleSetQuery' rows into a 'RoleSet'. Each row has exactly one
-- grant: a page (@(Just p, Nothing, Nothing)@), a wildcard action
-- (@(Nothing, Nothing, Just a)@), or a per-camera action
-- (@(Nothing, Just cam, Just a)@). Malformed rows contribute nothing.
buildRoleSet :: [(Maybe PageKind, Maybe CameraId, Maybe CameraAction)] -> RoleSet
buildRoleSet = foldMap step
  where
    step (Just p, Nothing, Nothing) = emptyRoleSet {rsPages = Set.singleton p}
    step (Nothing, Nothing, Just a) = emptyRoleSet {rsCamWildcard = Set.singleton a}
    step (Nothing, Just cam, Just a) =
      emptyRoleSet {rsCamPer = Map.singleton cam (Set.singleton a)}
    step _ = emptyRoleSet

-- | The SQL projection of a user's effective grants — the single source
-- of truth shared by the end-user app and hnvr-admin. Takes the user id
-- as @$1@; returns rows of @(page_kind, camera_id, camera_action)@ with
-- exactly one grant per row (see 'buildRoleSet').
roleSetQuery :: Text
roleSetQuery =
  "SELECT rp.page::text, NULL::uuid, NULL::text \
  \FROM user_roles ur \
  \JOIN role_page_perms rp ON rp.role_id = ur.role_id \
  \WHERE ur.user_id = $1 \
  \UNION ALL \
  \SELECT NULL::text, rcp.camera_id, rcp.action::text \
  \FROM user_roles ur \
  \JOIN role_camera_perms rcp ON rcp.role_id = ur.role_id \
  \WHERE ur.user_id = $1"

-- | Well-known seeded role ids (migration 0016-roles-acl).
superadminRoleId, guestRoleId :: UUID
superadminRoleId = wellKnown "00000000-0000-4000-8000-000000000001"
guestRoleId = wellKnown "00000000-0000-4000-8000-000000000002"

wellKnown :: Text -> UUID
wellKnown t = fromMaybe (error ("Authz: bad well-known UUID " <> show t)) (UUID.fromText t)

cameraActionToText :: CameraAction -> Text
cameraActionToText a = case a of
  ViewLive -> "view_live"
  ViewConfig -> "view_config"
  EditConfig -> "edit_config"
  DeleteCamera -> "delete_camera"
  PtzMove -> "ptz_move"
  PtzPreset -> "ptz_preset"
  ViewArchive -> "view_archive"
  PurgeArchive -> "purge_archive"
  ManageEvents -> "manage_events"

cameraActionFromText :: Text -> Maybe CameraAction
cameraActionFromText t = case t of
  "view_live" -> Just ViewLive
  "view_config" -> Just ViewConfig
  "edit_config" -> Just EditConfig
  "delete_camera" -> Just DeleteCamera
  "ptz_move" -> Just PtzMove
  "ptz_preset" -> Just PtzPreset
  "view_archive" -> Just ViewArchive
  "purge_archive" -> Just PurgeArchive
  "manage_events" -> Just ManageEvents
  _ -> Nothing

pageKindToText :: PageKind -> Text
pageKindToText p = case p of
  PageDashboard -> "dashboard"
  PageLive -> "live"
  PageArchive -> "archive"
  PageEvents -> "events"
  PageRules -> "rules"
  PageHosts -> "hosts"
  PageSettings -> "settings"

pageKindFromText :: Text -> Maybe PageKind
pageKindFromText t = case t of
  "dashboard" -> Just PageDashboard
  "live" -> Just PageLive
  "archive" -> Just PageArchive
  "events" -> Just PageEvents
  "rules" -> Just PageRules
  "hosts" -> Just PageHosts
  "settings" -> Just PageSettings
  _ -> Nothing
