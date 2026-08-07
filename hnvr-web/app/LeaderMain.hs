-- | Entry point for the @hnvr-leader@ binary.
--
-- Runs on the RTX 4090 host only. Carries:
--
--   * IHP webserver (Warp on port 8000)
--   * CaptureSupervisor + AnalyzerSupervisor + PtzSupervisor (worker role)
--   * EventWriter (drains @hnvr.events@ → Postgres)
--   * MediaMTXConfigSyncer (watches cameras table → rewrites mediamtx.yml)
--   * RetentionSweeper (hourly SeaweedFS + Postgres cleanup)
--   * AssignmentCoordinator (camera → host)
--   * LeaderLease (JetStream KV TTL)
--
-- Implementation lands in Phase 0 (bootstrap) and grows per roadmap.
module Main (main) where

import qualified Data.Text as T
import qualified Hnvr.Web

main :: IO ()
main = do
  putStrLn $ "hnvr-leader v" <> T.unpack Hnvr.Web.version
  putStrLn "Bootstrap stub. See design_docs/08-roadmap.md for implementation phases."
