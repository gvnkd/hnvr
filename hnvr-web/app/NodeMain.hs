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
-- Implementation lands in Phase 0 (bootstrap).
module Main (main) where

import qualified Data.Text as T
import qualified Hnvr.Web

main :: IO ()
main = do
  putStrLn $ "hnvr-node v" <> T.unpack Hnvr.Web.version
  putStrLn "Bootstrap stub. See design_docs/08-roadmap.md for implementation phases."
