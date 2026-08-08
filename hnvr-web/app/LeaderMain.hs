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
-- Phase 0 wires IHP and the @/healthz@ route; the rest lands per roadmap.
module Main (main) where

import Hnvr.Web.Config (config)
import Hnvr.Web.FrontController ()
import qualified IHP.Server

-- brings FrontController/Worker RootApplication instances

main :: IO ()
main = IHP.Server.run config
