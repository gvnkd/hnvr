{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | IHP FrameworkConfig for HNVR's leader node.
--
-- This is the bridge between IHP's runtime and our app. We use IHP for the
-- web/HTTP layer (controllers, sessions, schema designer hook points) but
-- we override the WAI middleware to serve @/healthz@ without touching the
-- database — important because Postgres is a SaaS dependency that may be
-- unreachable during early boot, but healthchecks must always succeed.
--
-- The leader also opens a NATS bus connection at startup via
-- 'addInitializer'. The connection persists for the lifetime of the
-- process (nats-queue runs an internal receiver thread). Phase 1 will
-- store the handle in an MVar so 'EventWriter' can publish on it.
module Hnvr.Web.Config
  ( config,
  )
where

import qualified Control.Exception as E
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Web.EventWriter (startEventWriter)
import IHP.FrameworkConfig
import IHP.FrameworkConfig.Types (FrameworkConfig)
import IHP.ModelSupport (ModelContext)
import IHP.Prelude
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai
import qualified Network.Wai.Middleware.HealthCheckEndpoint as HealthCheck
import qualified System.Environment as Env

-- | 'IHP.FrameworkConfig.ConfigBuilder' consumed by @IHP.Server.run@.
config :: ConfigBuilder
config = do
  option $ CustomMiddleware healthzMiddleware
  addInitializer connectNatsAndStartEventWriter

-- | Connect to the NATS bus using @HNVR_NATS_URI@ (default localhost),
-- then spawn the EventWriter drain loop on the same bus. Best-effort: if
-- NATS is unreachable (race with systemd ordering, network not yet up,
-- broker down), we log and continue. Phase 0 needs /healthz to succeed
-- even when NATS is flapping. systemd's @Restart=on-failure@ will still
-- catch real crashes.
connectNatsAndStartEventWriter :: (?context :: FrameworkConfig, ?modelContext :: ModelContext) => IO ()
connectNatsAndStartEventWriter = do
  let defaultUri = "nats://nats:nats@localhost:4222"
  uri <- maybe defaultUri id <$> Env.lookupEnv "HNVR_NATS_URI"
  let connect' = do
        bus <- Bus.connect Bus.defaultConfig {Bus.busUri = uri}
        putStrLn ("HNVR leader connected to NATS: " <> cs (uri :: String))
        startEventWriter bus ?modelContext
  connect' `E.catch` \(e :: E.SomeException) ->
    putStrLn ("HNVR leader: NATS connect failed (continuing without bus): " <> cs (show e))

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
