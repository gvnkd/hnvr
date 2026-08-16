{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedRecordDot #-}
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
-- Payload: camera states come from the CaptureSupervisor via the
-- process-wide 'Hnvr.Web.SupervisorRegistry' (both binaries write their
-- supervisor there after creation). cpu_pct (delta of /proc/stat
-- between ticks), ram_bytes (/proc/meminfo used) and gpu_mem_bytes
-- (nvidia-smi VRAM sum) are sampled per tick; the two Maybe fields go
-- null on hosts where the source is absent rather than lying with 0.
module Hnvr.Node.HealthReporter
  ( startHealthReporter,
    Health (..),
  )
where

import Control.Applicative ((<|>))
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Exception (SomeException, try)
import Data.Aeson (ToJSON, object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Char8 as LBS
import Data.IORef (readIORef)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (getCurrentTime)
import Hnvr.Capture.Worker (captureStateWire)
import Hnvr.Core.CameraStatus (CameraHealth (..))
import Hnvr.Core.Logging (logInfo, logWarn)
import Hnvr.Cv.Analyzer (execProviderName, execProvidersFromEnv)
import Hnvr.Nats.Bus (Bus)
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Nats.Subjects (health)
import Hnvr.Node.CaptureSupervisor (CameraStateInfo (..), cameraStates)
import Hnvr.Web.SupervisorRegistry (supervisorRegistry)
import qualified System.Environment as Env
import System.Exit (ExitCode (..))
import qualified System.Process.Typed as Proc
import Text.Read (readMaybe)

-- | Per-host heartbeat payload. Field names match the JSON wire format
-- documented in @design_docs/01-architecture.md@. @cameras@ carries
-- per-camera worker states ('CameraHealth') so the leader's UI can
-- tell a recording camera from a dead one.
data Health = Health
  { hHost :: !Text,
    hTimestamp :: !Text, -- ISO8601 UTC, populated at publish time
    hCameras :: ![CameraHealth],
    hCpuPct :: !Double,
    hGpuModel :: !(Maybe Text),
    -- | Active ONNX Runtime EPs in priority order
    -- ('Hnvr.Cv.Analyzer.execProvidersFromEnv'), resolved once at
    -- startup — the env var can't change without a restart.
    hExecProviders :: ![Text],
    hGpuMemBytes :: !(Maybe Integer),
    hRamBytes :: !(Maybe Integer)
  }

instance ToJSON Health where
  toJSON h =
    object
      [ "host" .= h.hHost,
        "ts" .= h.hTimestamp,
        "cameras" .= h.hCameras,
        "cpu_pct" .= h.hCpuPct,
        "gpu_model" .= h.hGpuModel,
        "exec_providers" .= h.hExecProviders,
        "gpu_mem_bytes" .= h.hGpuMemBytes,
        "ram_bytes" .= h.hRamBytes
      ]

-- | Spawn the heartbeat loop in a background async. Returns immediately.
-- The async lives for the lifetime of the process; on NATS disconnect,
-- publish calls swallow errors silently (nats-queue core semantics) so
-- the loop doesn't die — it just produces into the void until NATS
-- reconnects. The GPU model is resolved once at startup (it can't
-- change without a reboot); the HealthCache persists it into
-- @hosts.gpu_model@ for the dashboard/Hosts pages.
startHealthReporter :: Bus -> Text -> IO ()
startHealthReporter bus host = do
  gpuModel <- detectGpuModel
  eps <- map execProviderName <$> execProvidersFromEnv
  -- Prime the CPU sampler so the first published tick already carries
  -- a real 5 s average instead of a meaningless 0.
  cpu0 <- readCpuSample
  let loop prevCpu = do
        now <- getCurrentTime
        mSup <- readIORef supervisorRegistry
        cams <- maybe (pure []) cameraStates mSup
        mCpuNow <- readCpuSample
        gpuMem <- sampleGpuMemBytes
        ram <- sampleRamBytes
        let payload =
              Health
                { hHost = host,
                  hTimestamp = T.pack (show now),
                  hCameras = map (\c -> CameraHealth c.csiSlug (captureStateWire c.csiState)) cams,
                  hCpuPct = fromMaybe 0 (cpuPctBetween <$> prevCpu <*> mCpuNow),
                  hGpuModel = gpuModel,
                  hExecProviders = eps,
                  hGpuMemBytes = gpuMem,
                  hRamBytes = ram
                }
        Bus.publishJson bus (health host) payload
        threadDelay 5_000_000
        loop (mCpuNow <|> prevCpu)
  _ <- async (loop cpu0)
  logInfo ("HealthReporter: publishing hnvr.health." <> host <> " every 5s")

-- | GPU model via nvidia-smi (same binary 'Hnvr.Web.Metrics.startGpuPoller'
-- uses for VRAM). 'Nothing' on any failure — CPU-only hosts and missing
-- drivers must not kill the reporter; the UI renders \"—\" for NULL.
detectGpuModel :: IO (Maybe Text)
detectGpuModel = do
  r <- try (Proc.readProcessStdout (Proc.proc "nvidia-smi" ["--query-gpu=name", "--format=csv,noheader"]))
  case r of
    Left (e :: SomeException) -> do
      logWarn ("HealthReporter: nvidia-smi failed (" <> T.pack (show e) <> "); gpu_model unset")
      pure Nothing
    Right (ExitFailure code, _) -> do
      logWarn ("HealthReporter: nvidia-smi exited " <> T.pack (show code) <> "; gpu_model unset")
      pure Nothing
    Right (ExitSuccess, out) ->
      case filter (not . T.null) (map T.strip (T.lines (TE.decodeUtf8 (BL.toStrict out)))) of
        [] -> pure Nothing
        models -> pure (Just (T.intercalate ", " models))

-- | Used VRAM in bytes, summed across GPUs (MiB from nvidia-smi ×
-- 1024², same query as 'Hnvr.Web.Metrics.startGpuPoller'). 'Nothing'
-- when nvidia-smi is absent/fails — GPU-less hosts publish null.
sampleGpuMemBytes :: IO (Maybe Integer)
sampleGpuMemBytes = do
  r <-
    try
      ( snd
          <$> Proc.readProcessStdout
            (Proc.proc "nvidia-smi" ["--query-gpu=memory.used", "--format=csv,noheader,nounits"])
      ) ::
      IO (Either SomeException LBS.ByteString)
  pure $ case r of
    Left _ -> Nothing
    Right out ->
      let mib = sum (mapMaybe (readMaybe . LBS.unpack) (LBS.lines out))
       in Just (mib * 1024 * 1024)

-- | Used RAM in bytes: (MemTotal − MemAvailable) × 1024 from
-- /proc/meminfo. 'Nothing' on unparseable/missing (non-Linux).
sampleRamBytes :: IO (Maybe Integer)
sampleRamBytes = do
  r <- try (readFile "/proc/meminfo") :: IO (Either SomeException String)
  pure $ case r of
    Left _ -> Nothing
    Right s -> do
      total <- lookupField "MemTotal" s
      avail <- lookupField "MemAvailable" s
      Just ((total - avail) * 1024)
  where
    lookupField key s =
      case [v | l <- lines s, (k : v : _) <- [words l], k == key <> ":"] of
        (n : _) -> readMaybe n
        _ -> Nothing

-- | Aggregate CPU jiffies from the first line of /proc/stat
-- (idle = idle + iowait; total = sum of the first 8 counters — guest
-- time is already accounted inside user/nice).
data CpuSample = CpuSample
  { csIdle :: !Integer,
    csTotal :: !Integer
  }

readCpuSample :: IO (Maybe CpuSample)
readCpuSample = do
  r <- try (readFile "/proc/stat") :: IO (Either SomeException String)
  pure $ case r of
    Left _ -> Nothing
    Right s -> case lines s of
      (l : _) ->
        let vals = mapMaybe readMaybe (take 8 (drop 1 (words l)))
         in if length vals >= 5
              then Just (CpuSample (vals !! 3 + vals !! 4) (sum vals))
              else Nothing
      _ -> Nothing

-- | Busy percentage between two samples; 0 when the counters didn't
-- advance (first tick after a failed prime, etc.).
cpuPctBetween :: CpuSample -> CpuSample -> Double
cpuPctBetween a b
  | dTotal <= 0 = 0
  | otherwise = 100 * fromIntegral (dTotal - dIdle) / fromIntegral dTotal
  where
    dIdle = b.csIdle - a.csIdle
    dTotal = b.csTotal - a.csTotal
