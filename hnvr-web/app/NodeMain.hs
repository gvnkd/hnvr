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
-- node is visibly present in @nats-server@ monitoring. Real workers
-- (CaptureSupervisor et al) land in Phase 2.
module Main (main) where

import Control.Concurrent (threadDelay)
import Control.Monad (forever, void)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Hnvr.Nats.Bus as Bus
import qualified System.Environment as Env

main :: IO ()
main = do
  let defaultUri = "nats://nats:nats@localhost:4222" :: Text
  uri <- maybe defaultUri T.pack <$> Env.lookupEnv "HNVR_NATS_URI"
  Bus.withBus Bus.defaultConfig {Bus.busUri = T.unpack uri} $ \bus -> do
    _sub <- Bus.subscribe bus "hnvr.commands.>"
    putStrLn $ "hnvr-node connected to NATS: " <> T.unpack uri
    putStrLn $
      "hnvr-node subscribed to hnvr.commands.> "
        <> "(Phase 0 stub; real dispatch lands in Phase 2)"
    void $ forever $ do
      threadDelay 1000000000
