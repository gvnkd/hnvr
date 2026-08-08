{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | IHP FrameworkConfig for HNVR's leader node.
--
-- This is the bridge between IHP's runtime and our app. We use IHP for the
-- web/HTTP layer (controllers, sessions, schema designer hook points) but
-- we override the WAI middleware to serve @/healthz@ without touching the
-- database — important because Postgres is a SaaS dependency that may be
-- unreachable during early boot, but healthchecks must always succeed.
module Hnvr.Web.Config
  ( config,
  )
where

import IHP.FrameworkConfig
import IHP.Prelude
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai
import qualified Network.Wai.Middleware.HealthCheckEndpoint as HealthCheck

-- | 'IHP.FrameworkConfig.ConfigBuilder' consumed by @IHP.Server.run@.
--
-- Adds our 'healthzMiddleware' on top of IHP's default stack. IHP's own
-- @/_healthz@ is wired only when @IHP_SYSTEMD=true@; we always serve both
-- @/healthz@ and @/_healthz@ so monitoring can use either form.
config :: ConfigBuilder
config = do
  option $ CustomMiddleware healthzMiddleware

-- | WAI middleware that short-circuits @/healthz@ and @/_healthz@ with 200 OK.
-- Falls through to the inner IHP app for everything else.
healthzMiddleware :: Wai.Middleware
healthzMiddleware app request respond
  | path == "/healthz" = respond okResponse
  | otherwise = HealthCheck.healthCheck app request respond
  where
    path = Wai.rawPathInfo request :: ByteString
    okResponse =
      Wai.responseLBS
        HTTP.status200
        [ ("Content-Type", "text/plain; charset=utf-8")
        ]
        "ok"
