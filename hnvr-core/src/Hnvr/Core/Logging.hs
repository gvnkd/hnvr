{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Logging abstraction.
--
-- In production this is wired to @fast-logger@ writing per-worker files under
-- @/var/log/hnvr/@. In tests it can be a pure @Writer@-style implementation.
--
-- See @design_docs/01-architecture.md@ ("Telemetry" section).
--
-- All 'logIO' variants take a process-global 'MVar' lock so concurrent
-- 'async' threads (workers, HealthReporter, CaptureSupervisor, etc.)
-- can't interleave each other's lines on stdout. Without the lock,
-- 'Data.Text.IO.putStrLn' emits one write per codepoint through GHC's
-- encoding layer — two threads logging in parallel produce garbage
-- like @f[[lbloaoocwrk__ye2an_rt5d   IIINNNFFFOOO]]]@ (two distinct
-- messages interleaved character-by-character).
module Hnvr.Core.Logging
  ( LogLevel (..),
    Logger (..),
    logIO,
    logInfo,
    logWarn,
    logError,
    logDebug,
  )
where

import Control.Concurrent.MVar (MVar, newMVar, withMVar)
import Data.Text (Text)
import qualified Data.Text.IO as TIO
import GHC.Generics (Generic)
import System.IO (hFlush, stdout)
import System.IO.Unsafe (unsafePerformIO)

data LogLevel = Debug | Info | Warn | Error
  deriving stock
    ( Eq,
      Ord,
      Show,
      Enum,
      Bounded,
      Generic
    )

-- | Capability-style logging interface — any monad that can log implements this.
class Logger m where
  logAt :: LogLevel -> Text -> m ()

-- | Process-global stdout lock. Allocated once at module load via
-- 'unsafePerformIO'; the 'MVar' is shared across all threads. The
-- 'withMVar' bracket gives us strict mutual exclusion for the
-- putStrLn + hFlush pair, which is what we need for line-atomic
-- output. The unsafety is contained — no inlining, the MVar is
-- allocated exactly once.
{-# NOINLINE logLock #-}
logLock :: MVar ()
logLock = unsafePerformIO (newMVar ())

-- | Stdout line logger. Format: @HNVR [LEVEL] <msg>@. Flushes after every
-- line so logs aren't lost if the leader is killed by timeout / SIGTERM.
-- The MVar lock ensures concurrent threads don't interleave characters
-- on the shared stdout handle.
logIO :: LogLevel -> Text -> IO ()
logIO lvl msg =
  withMVar logLock $ \_ -> do
    TIO.putStrLn ("HNVR [" <> levelTag lvl <> "] " <> msg)
    hFlush stdout
  where
    levelTag Debug = "DEBUG"
    levelTag Info = "INFO"
    levelTag Warn = "WARN"
    levelTag Error = "ERROR"

logInfo, logWarn, logError, logDebug :: Text -> IO ()
logInfo = logIO Info
logWarn = logIO Warn
logError = logIO Error
logDebug = logIO Debug
