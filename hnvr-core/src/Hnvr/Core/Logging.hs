{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Logging abstraction.
--
-- In production this is wired to @fast-logger@ writing per-worker files under
-- @/var/log/hnvr/@. In tests it can be a pure @Writer@-style implementation.
--
-- See @design_docs/01-architecture.md@ ("Telemetry" section).
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

import Data.Text (Text)
import qualified Data.Text.IO as TIO
import GHC.Generics (Generic)
import System.IO (hFlush, stdout)

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

-- | Stdout line logger. Format: @HNVR [LEVEL] <msg>@. Flushes after every
-- line so logs aren't lost if the leader is killed by timeout / SIGTERM.
logIO :: LogLevel -> Text -> IO ()
logIO lvl msg = do
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
