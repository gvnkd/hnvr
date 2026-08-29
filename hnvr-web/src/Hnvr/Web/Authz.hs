{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Roles & ACL enforcement for the end-user app
-- (design_docs/13-roles-and-acl.md, milestone M2).
--
-- 'authzMiddleware' runs inside the 'IHP.FrameworkConfig.Types.AuthMiddleware'
-- composition (after 'IHP.LoginSupport.Middleware.authMiddleware', so the
-- session user is already in the vault) and resolves the request's
-- 'RoleSet' once, storing it in the request vault. Controllers enforce
-- via 'ensurePerm' \/ 'ensurePagePerm' and filter camera lists via
-- 'aclFilterCameras'; views read the pure 'currentRoleSet' to hide
-- affordances (hide, don't 403 — but enforce anyway).
--
-- Subjects:
--
--   * @HNVR_DISABLE_AUTHZ=1@ → 'fullRoleSet' for everyone (e2e leader
--     gate, same family as the other @HNVR_DISABLE_*@ switches).
--   * @users.is_admin = TRUE@ → 'fullRoleSet' (fallback until the M5
--     backfill drops the column — a halfway deployment never locks you
--     out).
--   * logged-in user → union over @user_roles@.
--   * anonymous → the seeded @guest@ role.
--
-- RoleSet lookups are cached process-wide (30 s TTL); @LISTEN
-- roles_events@ ('startAuthzCacheInvalidator') busts the cache on admin
-- mutations. DB errors fail CLOSED (empty set) and are logged.
--
-- The middleware also owns the @\/whep\/\<slug\>@ ACL boundary: the WHEP
-- proxy lives here (not in 'Hnvr.Web.Config''s CustomMiddleware, which
-- runs before session/auth) so 'ViewLive' is checked before proxying to
-- MediaMTX. Denied or unknown slugs get a 404 — hiding, not leaking.
module Hnvr.Web.Authz
  ( authzMiddleware,
    currentRoleSet,
    currentIsSuperadmin,
    ensurePerm,
    ensurePagePerm,
    ensurePermAnywhere,
    ensureSuperadmin,
    toCameraId,
    aclFilterCameras,
    aclCameraIds,
    startAuthzCacheInvalidator,
    authzDisabled,
  )
where

import qualified Control.Exception as E
import Control.Monad (forever, void)
import qualified Data.ByteString.Char8 as BSC
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Data.UUID (UUID)
import qualified Data.Vault.Lazy as Vault
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.Notification as PGN
import Database.PostgreSQL.Simple.Types (Only (..), Query (..))
import Generated.Types
import Hnvr.Core.Authz
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Core.Logging (logError, logInfo)
import Hnvr.Web.Auth ()
import Hnvr.Web.WhepProxy (defaultMediaMtxWebrtc, proxyOne)
import IHP.Controller.AccessDenied (accessDeniedUnless)
import IHP.ControllerPrelude
import IHP.ControllerSupport (Respond)
import IHP.LoginSupport.Types (currentUserVaultKey, lookupAuthVault)
import IHP.ModelSupport (Id' (Id))
import IHP.RequestVault.ModelContext ()
import qualified Network.HTTP.Client as HC
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai
import qualified System.Environment as Env
import System.IO.Unsafe (unsafePerformIO)

-- | Global kill switch, read once at process start (env is immutable
-- per process). When True, every subject resolves to 'fullRoleSet' and
-- no enforcement fires.
{-# NOINLINE authzDisabled #-}
authzDisabled :: Bool
authzDisabled = unsafePerformIO ((== Just "1") <$> Env.lookupEnv "HNVR_DISABLE_AUTHZ")

-- | Who the request acts as: a logged-in user or a bare role (the
-- seeded guest role for anonymous requests).
data Subject = SubjectUser !UUID | SubjectRole !UUID
  deriving stock (Eq, Ord, Show)

{-# NOINLINE roleSetVaultKey #-}
roleSetVaultKey :: Vault.Key RoleSet
roleSetVaultKey = unsafePerformIO Vault.newKey

{-# NOINLINE subjectVaultKey #-}
subjectVaultKey :: Vault.Key Subject
subjectVaultKey = unsafePerformIO Vault.newKey

-- | Whether the subject holds the seeded superadmin role (or is_admin —
-- same privilege until the M5 backfill). The hnvr-admin service gates
-- every action on this.
{-# NOINLINE superVaultKey #-}
superVaultKey :: Vault.Key Bool
superVaultKey = unsafePerformIO Vault.newKey

-- | Process-wide RoleSet cache: subject → (fetchedAt, set, isSuperadmin).
-- 30 s TTL is the backstop; @LISTEN roles_events@ invalidates
-- immediately on admin mutations.
{-# NOINLINE cacheRef #-}
cacheRef :: IORef (Map Subject (UTCTime, RoleSet, Bool))
cacheRef = unsafePerformIO (newIORef Map.empty)

cacheTtl :: NominalDiffTime
cacheTtl = 30

-- | The request's effective 'RoleSet', resolved by 'authzMiddleware'.
-- Pure — safe to call from views. 'emptyRoleSet' (default-deny) when
-- the middleware never ran (defensive; dynamic requests always pass
-- through it).
currentRoleSet :: (?request :: Wai.Request) => RoleSet
currentRoleSet = fromMaybe emptyRoleSet (Vault.lookup roleSetVaultKey (Wai.vault ?request))

-- | Whether the current subject is a superadmin (see 'superVaultKey').
currentIsSuperadmin :: (?request :: Wai.Request) => Bool
currentIsSuperadmin = fromMaybe False (Vault.lookup superVaultKey (Wai.vault ?request))

-- | Enforce a per-camera action; 403 (early return) on deny.
ensurePerm :: (?request :: Wai.Request, ?respond :: Respond) => CameraAction -> CameraId -> IO ()
ensurePerm action cam = accessDeniedUnless (cameraAllowed currentRoleSet action cam)

-- | Enforce a page grant; 403 (early return) on deny.
ensurePagePerm :: (?request :: Wai.Request, ?respond :: Respond) => PageKind -> IO ()
ensurePagePerm page = accessDeniedUnless (pageAllowed currentRoleSet page)

-- | Enforce that an action is granted on at least one camera — for
-- mutations not tied to a concrete camera (e.g. camera creation).
ensurePermAnywhere :: (?request :: Wai.Request, ?respond :: Respond) => CameraAction -> IO ()
ensurePermAnywhere action = accessDeniedUnless (cameraAllowedAnywhere currentRoleSet action)

-- | Enforce superadmin (the hnvr-admin front door); 403 on deny.
ensureSuperadmin :: (?request :: Wai.Request, ?respond :: Respond) => IO ()
ensureSuperadmin = accessDeniedUnless currentIsSuperadmin

-- | Helper for 'ensurePerm' call sites holding an IHP 'Id'' — unwrap
-- without repeating the pitfall-#39 dance everywhere.
toCameraId :: Id' "cameras" -> CameraId
toCameraId (Id uuid) = CameraId uuid

-- | Restrict a cameras query to the subject's ACL for the action
-- (\"filter in SQL\"). No-op when the subject is unrestricted (disabled
-- gate, is_admin fallback, or full wildcard+overrides for the action —
-- see 'needsAclFilter').
aclFilterCameras ::
  (?modelContext :: ModelContext, ?request :: Wai.Request) =>
  CameraAction ->
  QueryBuilder "cameras" ->
  IO (QueryBuilder "cameras")
aclFilterCameras action q = do
  mIds <- aclCameraIds action
  pure $ case mIds of
    Nothing -> q
    Just ids -> q |> filterWhereIn (#id, map Id ids)

-- | The camera ids the subject may @action@, or 'Nothing' when
-- unfiltered. SQL is the single source of truth for the listing
-- ('visibleCameraIdsForUserQuery' in "Hnvr.Core.Authz").
aclCameraIds ::
  (?modelContext :: ModelContext, ?request :: Wai.Request) =>
  CameraAction ->
  IO (Maybe [UUID])
aclCameraIds action
  | not (needsAclFilter action currentRoleSet) = pure Nothing
  | otherwise = case Vault.lookup subjectVaultKey (Wai.vault ?request) of
      Just (SubjectUser uid) -> Just <$> run visibleCameraIdsForUserQuery (uid, actionT, actionT)
      Just (SubjectRole rid) -> Just <$> run visibleCameraIdsForRoleQuery (rid, actionT, actionT)
      -- No subject = middleware skipped (defensive) — list nothing
      -- rather than leak.
      Nothing -> pure (Just [])
  where
    actionT = cameraActionToText action
    run q params = do
      rows <- sqlQuery (toQuery q) params
      pure [u | Only u <- rows]

toQuery :: Text -> PG.Query
toQuery = Query . TE.encodeUtf8

-- | Middleware: resolve the request's subject + 'RoleSet' into the
-- vault, enforce the @\/whep\/\<slug\>@ ACL boundary (proxying allowed
-- streams to MediaMTX), pass everything else down the stack.
authzMiddleware :: Wai.Middleware
authzMiddleware app req respond = do
  let ?modelContext = req.modelContext
   in do
        (subject, rs, isSuper) <- resolve req
        let vault' =
              Vault.insert roleSetVaultKey rs
                $ Vault.insert subjectVaultKey subject
                $ Vault.insert superVaultKey isSuper (Wai.vault req)
            req' = req {Wai.vault = vault'}
        if BSC.isPrefixOf "/whep/" (Wai.rawPathInfo req)
          then whepGuarded rs req' respond
          else app req' respond

-- | Subject + RoleSet + superadmin resolution. 'fullRoleSet'
-- short-circuits the DB fetch (disabled gate / is_admin fallback — both
-- are superadmin-equivalent).
resolve :: (?modelContext :: ModelContext) => Wai.Request -> IO (Subject, RoleSet, Bool)
resolve req = case lookupAuthVault currentUserVaultKey req of
  Just u
    | authzDisabled || u.isAdmin -> pure (SubjectUser (userUuid u), fullRoleSet, True)
    | otherwise -> do
        let uid = userUuid u
            subject = SubjectUser uid
        (rs, isSuper) <- cached subject (fetchUserRoleSet uid)
        pure (subject, rs, isSuper)
  Nothing
    | authzDisabled -> pure (SubjectRole guestRoleId, fullRoleSet, True)
    | otherwise -> do
        let subject = SubjectRole guestRoleId
        (rs, isSuper) <- cached subject (fetchRoleRoleSet guestRoleId)
        pure (subject, rs, isSuper)

userUuid :: User -> UUID
userUuid u = case u |> get #id of Id uuid -> uuid

-- | TTL-cached RoleSet fetch. Fail-closed on DB errors.
cached :: Subject -> IO (RoleSet, Bool) -> IO (RoleSet, Bool)
cached subject fetch' = do
  now <- getCurrentTime
  cachedMap <- readIORef cacheRef
  case Map.lookup subject cachedMap of
    Just (fetchedAt, rs, isSuper)
      | diffUTCTime now fetchedAt < cacheTtl -> pure (rs, isSuper)
    _ -> do
      (rs, isSuper) <-
        fetch' `E.catch` \(e :: E.SomeException) -> do
          logError ("Authz: RoleSet fetch failed for " <> cs (show subject) <> " (denying): " <> cs (show e))
          pure (emptyRoleSet, False)
      writeIORef cacheRef (Map.insert subject (now, rs, isSuper) cachedMap)
      pure (rs, isSuper)

fetchUserRoleSet :: (?modelContext :: ModelContext) => UUID -> IO (RoleSet, Bool)
fetchUserRoleSet uid = do
  rows <- sqlQuery (toQuery roleSetQuery) (uid, uid)
  superRows <- sqlQuery (toQuery superadminMembershipQuery) (uid, superadminRoleId)
  let isSuper = case superRows of
        [Only b] -> b
        _ -> False
  pure (buildRoleSet (map projectRow rows), isSuper)

fetchRoleRoleSet :: (?modelContext :: ModelContext) => UUID -> IO (RoleSet, Bool)
fetchRoleRoleSet rid = do
  rows <- sqlQuery (toQuery roleSetForRoleQuery) (rid, rid)
  pure (buildRoleSet (map projectRow rows), rid == superadminRoleId)

projectRow :: (Maybe Text, Maybe UUID, Maybe Text) -> (Maybe PageKind, Maybe CameraId, Maybe CameraAction)
projectRow (mp, mcam, ma) =
  ( mp >>= pageKindFromText,
    CameraId <$> mcam,
    ma >>= cameraActionFromText
  )

-- | @\/whep\/\<slug\>[@\/session\/\<id\>]@: allow only when the subject
-- has 'ViewLive' on the camera behind @\<slug\>@. Unknown slugs and
-- denials both answer 404 — the ACL boundary hides camera existence.
whepGuarded :: RoleSet -> Wai.Request -> (Wai.Response -> IO Wai.ResponseReceived) -> IO Wai.ResponseReceived
whepGuarded rs req respond = do
  allowed <-
    if authzDisabled
      then pure True
      else slugAllowed slug
  if allowed
    then do
      mgr <- HC.newManager HC.defaultManagerSettings
      base <- fromMaybe defaultMediaMtxWebrtc <$> Env.lookupEnv "HNVR_MEDIAMTX_WEBRTC"
      proxyOne mgr base req >>= respond
    else
      respond
        ( Wai.responseLBS
            HTTP.status404
            [("Content-Type", "text/plain; charset=utf-8")]
            "not found"
        )
  where
    slug = BSC.takeWhile (/= '/') (BSC.drop 6 (Wai.rawPathInfo req))
    slugAllowed s = do
      let ?modelContext = req.modelContext
       in do
            rows <- sqlQuery "SELECT id FROM cameras WHERE slug = ?" (Only (cs (BSC.unpack s) :: Text))
            case rows of
              [Only cid] -> pure (cameraAllowed rs ViewLive (CameraId cid))
              _ -> pure False

-- | @LISTEN roles_events@ on a dedicated pg-simple connection (pitfall
-- #41) and clear the RoleSet cache on any notification. The hnvr-admin
-- service (M3) issues @NOTIFY roles_events@ after role/assignment
-- mutations; the 30 s TTL is the backstop. Spawned from Config under
-- the @HNVR_DISABLE_AUTHZ@ gate.
startAuthzCacheInvalidator :: IO ()
startAuthzCacheInvalidator = do
  void (async loop)
  logInfo "Authz: cache invalidator listening on roles_events"
  where
    loop = do
      dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
      listenLoop dbUrl `E.catch` \(e :: E.SomeException) ->
        case E.fromException e of
          Just (E.SomeAsyncException _) -> E.throwIO e
          _ -> logError ("Authz: LISTEN roles_events loop died: " <> cs (show e))
    listenLoop dbUrl = do
      conn <- PG.connectPostgreSQL dbUrl
      _ <- PG.execute_ conn "LISTEN roles_events"
      forever $ do
        _ <- PGN.getNotification conn
        writeIORef cacheRef Map.empty
    defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"
