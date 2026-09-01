{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | IHP FrameworkConfig for hnvr-admin (design_docs/13, M3).
--
-- Differences from the leader's 'Hnvr.Web.Config':
--
--   * own session cookie name (@hnvr_admin@ — IHP hardcodes
--     @SESSION@; 'Hnvr.Web.SessionCookie' translates at the edge) —
--     an end-user session grants nothing here;
--   * port from @HNVR_ADMIN_PORT@ (default 18010; the leader's PORT is
--     ignored);
--   * auth chain reuses 'Hnvr.Web.Authz.authzMiddleware' — RoleSet
--     resolution and the superadmin flag come from the shared cache.
--     Every admin controller additionally gates on 'ensureSuperadmin'.
module AdminWeb.Config
  ( config,
  )
where

import AdminWeb.Bootstrap (bootstrapFromEnv)
import qualified Control.Exception as E
import Control.Monad (forM_)
import Data.IORef (writeIORef)
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Generated.Types
import Hnvr.Core.BasePath (splitBaseUrl)
import Hnvr.Core.Logging (logError, logInfo)
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Web.Auth ()
import Hnvr.Web.Authz (authzMiddleware)
import Hnvr.Web.BusRegistry (busRegistry)
import Hnvr.Web.SessionCookie (sessionCookieMiddleware)
import IHP.FrameworkConfig
import IHP.LoginSupport.Middleware (authMiddleware)
import IHP.ModelSupport (ModelContext)
import IHP.Prelude
import qualified System.Environment as Env
import Text.Read (readMaybe)
import qualified Web.Cookie as Cookie

config :: ConfigBuilder
config = do
  port <- liftIO adminPort
  option (AppPort port)
  (baseUrl, basePath, explicitUrl) <- liftIO (adminBaseUrl port)
  -- BaseUrl only when explicitly configured: otherwise IHP's default
  -- (hostname:port) is fine and first-write-wins would shadow it.
  forM_ explicitUrl (option . BaseUrl)
  option $ SessionCookie ((defaultIHPSessionCookie baseUrl) {Cookie.setCookieName = "hnvr_admin"})
  -- IHP IGNORES the cookie name above: initSessionMiddleware is
  -- `withSession store "SESSION" …` (IHP/Server.hs). On a shared
  -- vhost (leader at /, admin at a sub-path) both apps would read and
  -- write the same SESSION cookie and share sessions. The rename
  -- middleware translates hnvr_admin <-> SESSION at the edge
  -- ("Hnvr.Web.SessionCookie"); it must be the OUTERMOST middleware,
  -- which the CustomMiddleware slot is.
  option $ CustomMiddleware (sessionCookieMiddleware "hnvr_admin")
  option $ AuthMiddleware (authMiddleware @User . authzMiddleware)
  -- redirectToPath (IHP's only redirect primitive — redirectTo goes
  -- through it too) prepends Approot.getApproot, which the middleware
  -- stack reads from the APPROOT env var once at init. Point it at the
  -- full public URL (path included) so redirects stay under the mount.
  unless (T.null basePath)
    $ liftIO
    $ Env.lookupEnv "APPROOT"
    >>= \case
      Just _ -> pure ()
      Nothing -> Env.setEnv "APPROOT" (cs baseUrl)
  addInitializer seedBootstrap
  addInitializer connectNats
  where
    seedBootstrap =
      bootstrapFromEnv `E.catch` \(e :: E.SomeException) ->
        logError ("hnvr-admin: INITIAL_ADMIN_* seed failed: " <> cs (show e))

-- | Public base URL of the admin UI. @HNVR_ADMIN_BASE_URL@ (full URL,
-- path allowed — e.g. @https://nvr.example.com/admin@ for a reverse-
-- proxy sub-path mount) wins over the legacy host-only @IHP_BASE_URL@;
-- the fallback keeps the old localhost behaviour. Returns the base URL
-- (path included — redirects and the cookie's Secure flag need it),
-- the normalized mount prefix, and the explicitly configured URL.
adminBaseUrl :: Int -> IO (Text, Text, Maybe Text)
adminBaseUrl port = do
  explicit <- Env.lookupEnv "HNVR_ADMIN_BASE_URL"
  legacy <- Env.lookupEnv "IHP_BASE_URL"
  pure $ case explicit of
    Just url ->
      let (baseUrl, basePath) = splitBaseUrl (cs url)
       in (baseUrl, basePath, Just baseUrl)
    Nothing -> (maybe ("http://localhost:" <> tshow port) cs legacy, "", Nothing)

adminPort :: IO Int
adminPort = do
  mPort <- Env.lookupEnv "HNVR_ADMIN_PORT"
  pure (fromMaybe 18010 (mPort >>= readMaybe))

-- | Admin camera/rule mutations republish assign payloads to the owning
-- host exactly like the leader's controllers used to (design_docs/13 M4:
-- "NATS snapshot rebroadcast on admin mutations"). Best-effort: a bus
-- outage must not take the admin UI down.
connectNats :: (?context :: FrameworkConfig, ?modelContext :: ModelContext) => IO ()
connectNats = do
  uri <- fromMaybe "nats://nats:nats@localhost:4222" <$> Env.lookupEnv "HNVR_NATS_URI"
  connect' uri `E.catch` \(e :: E.SomeException) ->
    logError ("hnvr-admin: NATS connect failed (mutations will not rebroadcast): " <> cs (show e))
  where
    connect' uri = do
      bus <- Bus.connect Bus.defaultConfig {Bus.busUri = uri}
      writeIORef busRegistry (Just bus)
      logInfo "hnvr-admin: connected to NATS"
