{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}

-- | Logging abstraction.
--
-- In production this is wired to @fast-logger@ writing per-worker files under
-- @/var/log/hnvr/@. In tests it can be a pure @Writer@-style implementation.
--
-- See @design_docs/01-architecture.md@ ("Telemetry" section).
module Hnvr.Core.Logging
  ( LogLevel (..),
    Logger (..),
  )
where

import Data.Text (Text)
import GHC.Generics (Generic)

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
