{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | User CRUD + role assignment (design_docs/13, M3).
--
-- Role checkboxes are named @role_\<uuid\>@. The last-superadmin guards
-- ('canDeleteUser' / 'canRemoveSuperadminGrant' in "Hnvr.Core.Authz")
-- refuse to orphan the deployment; the is_admin flag is left alone here
-- (M5 owns its retirement).
module Web.Controller.Users
  ( UsersController (..),
  )
where

import AdminWeb.Audit (auditAdmin)
import AdminWeb.Grants
import AdminWeb.View.Users.Edit
import AdminWeb.View.Users.Index
import AdminWeb.View.Users.New
import Data.Aeson (object, (.=))
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Generated.Types
import Hnvr.Core.Authz
import Hnvr.Web.Auth ()
import Hnvr.Web.Authz (ensureSuperadmin)
import IHP.AuthSupport.Authentication (hashPassword)
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)
import IHP.ModelSupport (Id' (Id))

data UsersController
  = UsersAction
  | NewUserAction
  | CreateUserAction
  | EditUserAction {userId :: !(Id User)}
  | UpdateUserAction {userId :: !(Id User)}
  | -- | POST (not Delete* — pitfall #82).
    PurgeUserAction {userId :: !(Id User)}
  deriving stock (Eq, Show, Data)

instance AutoRoute UsersController

instance Controller UsersController where
  beforeAction = ensureIsUser

  action UsersAction = do
    ensureSuperadmin
    users <- query @User |> orderByAsc #email |> fetch
    roles <- query @Role |> orderByAsc #name |> fetch
    rows <- forM users $ \user -> do
      rids <- liftIO (fetchUserRoleIds (uuidOf user))
      pure (user, [r | r <- roles, uuidOf' r `elem` rids])
    render IndexView {users = rows}
  action NewUserAction = do
    ensureSuperadmin
    roles <- query @Role |> orderByAsc #name |> fetch
    let user = newRecord @User
        assigned = []
    render NewView {..}
  action CreateUserAction = do
    ensureSuperadmin
    let email = param @Text "email"
        password = param @Text "password"
    hash <- hashPassword password
    user <-
      newRecord @User
        |> set #email email
        |> set #passwordHash hash
        |> createRecord
    let rids = roleParams
    liftIO (replaceUserRoles (uuidOf user) rids)
    auditAdmin "user.create" "user" (Just (tshow (uuidOf user))) (Just (object ["email" .= email, "roles" .= map tshow rids]))
    setSuccessMessage ("User created: " <> email)
    redirectTo UsersAction
  action EditUserAction {userId} = do
    ensureSuperadmin
    user <- fetch userId
    roles <- query @Role |> orderByAsc #name |> fetch
    assigned <- liftIO (fetchUserRoleIds (uuidOf user))
    render EditView {..}
  action UpdateUserAction {userId} = do
    ensureSuperadmin
    user <- fetch userId
    let newRoles = roleParams
    holdsSuper <- liftIO (userHoldsSuperadmin (uuidOf user))
    let losesSuper = holdsSuper && superadminRoleId `notElem` newRoles
    holders <- liftIO countSuperadminHolders
    if losesSuper && not (canRemoveSuperadminGrant holders)
      then do
        setErrorMessage "Cannot remove the last superadmin grant"
        redirectTo EditUserAction {userId}
      else do
        user' <- case nonemptyParam "password" of
          Nothing -> pure user
          Just pw -> do
            hash <- hashPassword pw
            user |> set #passwordHash hash |> updateRecord
        liftIO (replaceUserRoles (uuidOf user') newRoles)
        auditAdmin
          "user.update"
          "user"
          (Just (tshow (uuidOf user')))
          (Just (object ["email" .= user'.email, "roles" .= map tshow newRoles]))
        setSuccessMessage ("User updated: " <> user'.email)
        redirectTo UsersAction
  action PurgeUserAction {userId} = do
    ensureSuperadmin
    user <- fetch userId
    holdsSuper <- liftIO (userHoldsSuperadmin (uuidOf user))
    holders <- liftIO countSuperadminHolders
    if not (canDeleteUser holdsSuper holders)
      then do
        setErrorMessage "Cannot delete the last superadmin"
        redirectTo UsersAction
      else do
        deleteRecord user
        liftIO notifyRolesChanged
        auditAdmin "user.delete" "user" (Just (tshow (uuidOf user))) (Just (object ["email" .= user.email]))
        setSuccessMessage ("User deleted: " <> user.email)
        redirectTo UsersAction

-- | Checked @role_\<uuid\>@ params.
roleParams :: (?request :: Request) => [UUID]
roleParams =
  [ rid
  | (k, v) <- allParams,
    v == Just "on",
    "role_" `T.isPrefixOf` cs k,
    Just rid <- [UUID.fromText (T.drop 5 (cs k))]
  ]

uuidOf :: User -> UUID
uuidOf u = case u |> get #id of Id uuid -> uuid

uuidOf' :: Role -> UUID
uuidOf' r = case r |> get #id of Id uuid -> uuid

-- | Optional param; empty string treated as absent.
nonemptyParam :: (?request :: Request) => ByteString -> Maybe Text
nonemptyParam name =
  case paramOrNothing name of
    Just t | not (T.null (T.strip t)) -> Just (T.strip t)
    _ -> Nothing
