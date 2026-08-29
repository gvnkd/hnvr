{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | IHP FrameworkConfig for hnvr-admin (design_docs/13, M3).
--
-- Differences from the leader's 'Hnvr.Web.Config':
--
--   * own session cookie name (@hnvr_admin@) — an end-user session
--     grants nothing here;
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
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import Generated.Types
import Hnvr.Core.Logging (logError)
import Hnvr.Web.Auth ()
import Hnvr.Web.Authz (authzMiddleware)
import IHP.FrameworkConfig
import IHP.LoginSupport.Middleware (authMiddleware)
import IHP.Prelude
import qualified System.Environment as Env
import Text.Read (readMaybe)
import qualified Web.Cookie as Cookie

config :: ConfigBuilder
config = do
  port <- liftIO adminPort
  option (AppPort port)
  baseUrl <- liftIO (maybe ("http://localhost:" <> tshow port) T.pack <$> Env.lookupEnv "IHP_BASE_URL")
  option $ SessionCookie ((defaultIHPSessionCookie baseUrl) {Cookie.setCookieName = "hnvr_admin"})
  option $ AuthMiddleware (authMiddleware @User . authzMiddleware)
  addInitializer seedBootstrap
  where
    seedBootstrap =
      bootstrapFromEnv `E.catch` \(e :: E.SomeException) ->
        logError ("hnvr-admin: INITIAL_ADMIN_* seed failed: " <> cs (show e))

adminPort :: IO Int
adminPort = do
  mPort <- Env.lookupEnv "HNVR_ADMIN_PORT"
  pure (fromMaybe 18010 (mPort >>= readMaybe))
