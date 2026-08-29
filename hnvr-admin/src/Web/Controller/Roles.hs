{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Roles CRUD + grant matrix (design_docs/13, M3).
--
-- Grant params on Create/Update: checkboxes named @page_\<kind\>@,
-- @wild_\<action\>@ and, per camera, @ovr_on_\<uuid\>@ (master) with
-- @ovr_\<uuid\>_\<action\>@ rows. Grants are replaced wholesale in one
-- transaction ('AdminWeb.Grants.replaceRoleGrants'), then
-- @NOTIFY roles_events@ busts every service's RoleSet cache.
--
-- System roles (superadmin/guest) are immutable: no edit, no delete
-- ('canDeleteRole'); the UI hides their affordances and the controller
-- enforces.
module Web.Controller.Roles
  ( RolesController (..),
  )
where

import AdminWeb.Audit (auditAdmin)
import AdminWeb.Grants
import AdminWeb.View.Roles.Edit
import AdminWeb.View.Roles.Index
import AdminWeb.View.Roles.New
import Control.Exception (bracket)
import Data.Aeson (object, (.=))
import qualified Data.ByteString.Char8 as BSC
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import qualified Database.PostgreSQL.Simple as PG
import Generated.Types
import Hnvr.Core.Authz
import Hnvr.Web.Auth ()
import Hnvr.Web.Authz (ensureSuperadmin)
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)
import IHP.ModelSupport (Id' (Id))
import qualified System.Environment as Env

data RolesController
  = RolesAction
  | NewRoleAction
  | CreateRoleAction
  | EditRoleAction {roleId :: !(Id Role)}
  | UpdateRoleAction {roleId :: !(Id Role)}
  | -- | POST (not Delete* — pitfall #82).
    PurgeRoleAction {roleId :: !(Id Role)}
  deriving stock (Eq, Show, Data)

instance AutoRoute RolesController

instance Controller RolesController where
  beforeAction = ensureIsUser

  action RolesAction = do
    ensureSuperadmin
    roles <- query @Role |> orderByAsc #name |> fetch
    rows <- forM roles $ \role -> do
      grants <- liftIO (fetchRoleGrants (uuidOf role))
      holders <- liftIO (countHolders (uuidOf role))
      pure (role, grants, holders)
    render IndexView {roles = rows}
  action NewRoleAction = do
    ensureSuperadmin
    cameras <- query @Camera |> orderByAsc #slug |> fetch
    let role = newRecord @Role
        grants = emptyRoleGrants
    render NewView {..}
  action CreateRoleAction = do
    ensureSuperadmin
    let name = param @Text "name"
        description = paramOrDefault ("" :: Text) "description"
    role <-
      newRecord @Role
        |> set #name name
        |> set #description description
        |> createRecord
    let (pages, wild, ovrs) = grantParams
    liftIO (replaceRoleGrants (uuidOf role) pages wild ovrs)
    auditAdmin "role.create" "role" (Just (tshow (uuidOf role))) (Just (object ["name" .= name]))
    setSuccessMessage ("Role created: " <> name)
    redirectTo RolesAction
  action EditRoleAction {roleId} = do
    ensureSuperadmin
    role <- fetch roleId
    if role.isSystem
      then do
        setErrorMessage ("System role " <> role.name <> " is immutable")
        redirectTo RolesAction
      else do
        grants <- liftIO (fetchRoleGrants (uuidOf role))
        cameras <- query @Camera |> orderByAsc #slug |> fetch
        render EditView {..}
  action UpdateRoleAction {roleId} = do
    ensureSuperadmin
    role <- fetch roleId
    if role.isSystem
      then do
        setErrorMessage ("System role " <> role.name <> " is immutable")
        redirectTo RolesAction
      else do
        before <- liftIO (fetchRoleGrants (uuidOf role))
        role' <-
          role
            |> set #name (param @Text "name")
            |> set #description (paramOrDefault ("" :: Text) "description")
            |> updateRecord
        let (pages, wild, ovrs) = grantParams
        liftIO (replaceRoleGrants (uuidOf role') pages wild ovrs)
        auditAdmin
          "role.update"
          "role"
          (Just (tshow (uuidOf role')))
          ( Just
              ( object
                  [ "name" .= role'.name,
                    "before_pages" .= map pageKindToText (before.rgPages),
                    "after_pages" .= map pageKindToText pages,
                    "before_wildcard" .= map cameraActionToText (before.rgWildcard),
                    "after_wildcard" .= map cameraActionToText wild
                  ]
              )
          )
        setSuccessMessage ("Role updated: " <> role'.name)
        redirectTo RolesAction
  action PurgeRoleAction {roleId} = do
    ensureSuperadmin
    role <- fetch roleId
    if not (canDeleteRole role.isSystem)
      then do
        setErrorMessage ("System role " <> role.name <> " cannot be deleted")
        redirectTo RolesAction
      else do
        holders <- liftIO (countHolders (uuidOf role))
        deleteRecord role
        liftIO notifyRolesChanged
        auditAdmin
          "role.delete"
          "role"
          (Just (tshow (uuidOf role)))
          (Just (object ["name" .= role.name, "holders" .= holders]))
        setSuccessMessage ("Role deleted: " <> role.name)
        redirectTo RolesAction

-- | Holder count for a role (for the index table + audit payload).
countHolders :: UUID -> IO Int
countHolders roleId = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn -> do
    rows <- PG.query conn "SELECT COUNT(*)::int FROM user_roles WHERE role_id = ?" (PG.Only roleId)
    pure (maybe 0 PG.fromOnly (safeHead rows))
  where
    safeHead [] = Nothing
    safeHead (x : _) = Just x

defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"

uuidOf :: Role -> UUID
uuidOf r = case r |> get #id of Id u -> u

-- | Parse the grant checkbox params. Per-camera overrides: a camera is
-- overridden iff @ovr_on_\<uuid\>@ is checked; its actions come from
-- @ovr_\<uuid\>_\<action\>@ checkboxes.
grantParams :: (?request :: Request) => ([PageKind], [CameraAction], [(UUID, [CameraAction])])
grantParams = (pages, wild, ovrs)
  where
    on name = paramOrNothing @Text (cs name) == Just "on"
    pages = [p | p <- allPageKinds, on ("page_" <> pageKindToText p)]
    wild = [a | a <- allCameraActions, on ("wild_" <> cameraActionToText a)]
    ovrs =
      [ (cam, actions)
      | cam <- overrideCameraIds,
        on ("ovr_on_" <> UUID.toText cam),
        let actions =
              [ a
              | a <- allCameraActions,
                on ("ovr_" <> UUID.toText cam <> "_" <> cameraActionToText a)
              ]
      ]
    -- Cameras appear as ovr_on_<uuid> master checkboxes; collect the
    -- uuids from the param namespace (params with that prefix).
    overrideCameraIds =
      mapMaybe (UUID.fromText . T.drop 7) (filter ("ovr_on_" `T.isPrefixOf`) allParamNames)
    allParamNames = map (cs . fst) allParams
