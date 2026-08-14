-- | Process-wide NATS Bus registry.
--
-- Same shape as "Hnvr.Web.SupervisorRegistry": the bus is connected in
-- an IHP initializer, so controllers can't receive it through
-- 'option'. One bus per process by design; a process-wide IORef is the
-- honest shape. Controllers that need to publish (Rules CRUD
-- rule-refresh, Phase 4) read it here; 'Nothing' when NATS was
-- unreachable at boot.
module Hnvr.Web.BusRegistry
  ( busRegistry,
  )
where

import Data.IORef (IORef, newIORef)
import Hnvr.Nats.Bus (Bus)
import System.IO.Unsafe (unsafePerformIO)

{-# NOINLINE busRegistry #-}
busRegistry :: IORef (Maybe Bus)
busRegistry = unsafePerformIO (newIORef Nothing)
