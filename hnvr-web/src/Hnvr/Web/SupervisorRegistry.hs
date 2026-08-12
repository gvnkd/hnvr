-- | Process-wide CaptureSupervisor registry.
--
-- The supervisor is created in an IHP initializer (after the
-- FrameworkConfig is built), so controllers and WAI middleware can't
-- receive it through 'option'. One supervisor exists per process by
-- design (leader or node), so a process-wide IORef is the honest
-- shape — same pattern as the OnnxRuntime global state.
module Hnvr.Web.SupervisorRegistry
  ( supervisorRegistry,
  )
where

import Data.IORef (IORef, newIORef)
import Hnvr.Node.CaptureSupervisor (CaptureSupervisor)
import System.IO.Unsafe (unsafePerformIO)

{-# NOINLINE supervisorRegistry #-}
supervisorRegistry :: IORef (Maybe CaptureSupervisor)
supervisorRegistry = unsafePerformIO (newIORef Nothing)
