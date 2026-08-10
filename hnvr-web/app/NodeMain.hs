{-# LANGUAGE OverloadedStrings #-}

-- | Entry point for the @hnvr-node@ binary.
--
-- Runs on every host (including the leader host, which spawns both binaries).
-- Carries:
--
--   * CaptureSupervisor + AnalyzerSupervisor + PtzSupervisor (one per assigned
--     camera)
--   * HealthReporter (publishes @hnvr.health.<host>@ every 5s)
--   * ConfigWatcher (subscribes @hnvr.config.>@, updates in-memory IORef)
--
-- No HTTP server. No Postgres credentials. Only NATS + SeaweedFS creds.
--
-- Phase 0 wires a NATS connection + a placeholder subscription so the
-- node is visibly present in @nats-server@ monitoring. HealthReporter
-- landed in Phase 2 Slice 4; CaptureSupervisor + ConfigWatcher land in
-- Phase 2 Slice 5.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (forever, void)
import Data.Maybe (maybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Node.ConfigWatcher (startConfigWatcher)
import Hnvr.Node.HealthReporter (startHealthReporter)
import qualified System.Environment as Env

main :: IO ()
main = do
  let defaultUri = "nats://nats:nats@localhost:4222" :: Text
  uri <- maybe defaultUri T.pack <$> Env.lookupEnv "HNVR_NATS_URI"
  Bus.withBus Bus.defaultConfig {Bus.busUri = T.unpack uri} $ \bus -> do
    host <- maybe "hnvr-1" T.pack <$> Env.lookupEnv "HNVR_HOST"
    startHealthReporter bus host
    startConfigWatcher bus host
    _sub <- Bus.subscribe bus "hnvr.commands.>"
    putStrLn $ "hnvr-node connected to NATS: " <> T.unpack uri
    putStrLn $
      "hnvr-node subscribed to hnvr.commands.> "
        <> "(CaptureSupervisor dispatch lands in Phase 3)"
    void $ forever $ do
      threadDelay 1000000000
