{-# LANGUAGE OverloadedStrings #-}

-- | Entry point for the @hnvr-node@ binary.
--
-- Runs on every host (including the leader host, which spawns both binaries).
-- Carries:
--
--   * CaptureSupervisor + AnalyzerSupervisor + PtzSupervisor (one per assigned
--     camera) — Phase 3.
--   * HealthReporter (publishes @hnvr.health.<host>@ every 5s)
--   * ConfigWatcher (subscribes @hnvr.commands.assign.>@ and
--     @hnvr.commands.control.<host>.>@; Phase 3 will dispatch to the
--     CaptureSupervisor; today both handlers just log).
--
-- No HTTP server. No Postgres credentials. Only NATS + SeaweedFS creds.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (forever, void)
import Data.Maybe (maybe)
import Data.Text (Text)
import qualified Data.Text as T
import Hnvr.Core.Logging (logInfo)
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
    logInfo ("node: connected to NATS: " <> uri)
    void $ forever $ do
      threadDelay 1000000000
