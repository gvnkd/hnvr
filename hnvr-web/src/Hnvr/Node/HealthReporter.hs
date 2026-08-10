{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Per-host HealthReporter.
--
-- Publishes @hnvr.health.<host>@ every 5 s with a JSON payload describing
-- the host's current state. Consumed by:
--
--   * Leader's @HealthCache@ → /hosts dashboard (Phase 2 Slice 4)
--   * Leader's @AssignmentCoordinator@ → host-down detection, 15 s
--     timeout (Phase 2 Slice 5)
--
-- Both binaries (leader + node) run a HealthReporter because both are
-- hosts — the leader also runs CaptureWorkers locally.
--
-- Payload is currently mostly stubs: camera list comes from integrating
-- CaptureSupervisor into the node process (Phase 3+); CPU/GPU/mem
-- wiring lands with EKG metrics (Phase 6). The host-down detection in
-- Slice 5 only needs the heartbeat itself, so the stubs are fine.
module Hnvr.Node.HealthReporter
  ( startHealthReporter,
    Health (..),
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Monad (forever, void)
import Data.Aeson (ToJSON, object, (.=))
import qualified Data.Aeson as Aeson
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime)
import Hnvr.Nats.Bus (Bus)
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Nats.Subjects (health)
import qualified System.Environment as Env

-- | Per-host heartbeat payload. Field names match the JSON wire format
-- documented in @design_docs/01-architecture.md@.
data Health = Health
  { hHost :: !Text,
    hTimestamp :: !Text, -- ISO8601 UTC, populated at publish time
    hCameras :: ![Text], -- slugs of cameras this host currently owns
    hCpuPct :: !Double,
    hGpuModel :: !Text,
    hGpuMemBytes :: !Integer,
    hRamBytes :: !Integer
  }

instance ToJSON Health where
  toJSON h =
    object
      [ "host" .= h.hHost,
        "ts" .= h.hTimestamp,
        "cameras" .= h.hCameras,
        "cpu_pct" .= h.hCpuPct,
        "gpu_model" .= h.hGpuModel,
        "gpu_mem_bytes" .= h.hGpuMemBytes,
        "ram_bytes" .= h.hRamBytes
      ]

-- | Spawn the heartbeat loop in a background async. Returns immediately.
-- The async lives for the lifetime of the process; on NATS disconnect,
-- publish calls swallow errors silently (nats-queue core semantics) so
-- the loop doesn't die — it just produces into the void until NATS
-- reconnects.
startHealthReporter :: Bus -> Text -> IO ()
startHealthReporter bus host = do
  _ <- async loop
  putStrLn ("HNVR HealthReporter: publishing hnvr.health." <> T.unpack host <> " every 5s")
  where
    loop = forever $ do
      now <- getCurrentTime
      let payload =
            Health
              { hHost = host,
                hTimestamp = T.pack (show now),
                hCameras = [], -- Slice 5+: populated from CaptureSupervisor
                hCpuPct = 0, -- Slice 6+: EKG
                hGpuModel = "stub",
                hGpuMemBytes = 0,
                hRamBytes = 0
              }
      Bus.publishJson bus (health host) payload
      threadDelay 5_000_000
