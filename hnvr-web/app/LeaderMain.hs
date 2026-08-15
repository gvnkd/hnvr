{-# LANGUAGE OverloadedStrings #-}

-- | Entry point for the @hnvr-leader@ binary.
--
-- Runs on the RTX 4090 host only. Carries:
--
--   * IHP webserver (Warp on port 8000)
--   * CaptureSupervisor + AnalyzerSupervisor + PtzSupervisor (worker role)
--   * EventWriter (drains @hnvr.events@ → Postgres)
--   * MediaMTXConfigSyncer (watches cameras table → rewrites mediamtx.yml)
--   * SnapshotResponder (answers node bootstrap requests)
--   * RetentionSweeper (hourly SeaweedFS + Postgres cleanup) — Phase 6
--   * AssignmentCoordinator (camera → host)
--   * LeaderLease (JetStream KV TTL) — Phase 6
--
-- Schema migrations run BEFORE IHP starts so the leader boots clean on
-- a fresh DB. After migrations, IHP's @Server.run@ wires all
-- leader-role + node-role initializers via 'Hnvr.Web.Config.config'.
module Main (main) where

import Hnvr.Core.Logging (logInfo)
import Hnvr.Web (versionText)
import Hnvr.Web.Config (config)
import Hnvr.Web.FrontController ()
import Hnvr.Web.SchemaMigration (runLeaderMigrations)
import qualified IHP.Server

-- brings FrontController/Worker RootApplication instances

main :: IO ()
main = do
  logInfo ("starting hnvr-leader, " <> versionText)
  runLeaderMigrations
  IHP.Server.run config
