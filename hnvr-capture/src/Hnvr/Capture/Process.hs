{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Exception-safe child-process teardown (pitfall #130).
--
-- GHC has no SIGCHLD auto-reaper: a 'ProcessHandle' that never gets
-- 'waitForProcess' becomes a zombie when the child exits, and stays
-- one until the whole leader exits. The capture workers block in a
-- stdout read loop, so a supervisor cancellation lands mid-read and
-- skips the trailing 'waitForProcess' — 'reapProcess' exists to be
-- the 'bracket' release for every ffmpeg lifetime.
--
-- Kill order matters: SIGTERM with a grace window (ffmpeg flushes the
-- fMP4 fragment in flight), then SIGKILL — a bare 'terminateProcess'
-- can hang forever on a network-stuck ffmpeg, and an unkillable wait
-- would hang @cancel@ itself. The whole teardown runs under
-- 'uninterruptibleMask_' so a second cancellation can't punch out
-- halfway through and re-create the zombie.
module Hnvr.Capture.Process
  ( reapProcess,
  )
where

import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, try, uninterruptibleMask_)
import Control.Monad (unless, void, when)
import Data.Maybe (isNothing)
import qualified System.Posix.Signals as Sig
import System.Process
  ( ProcessHandle,
    getProcessExitCode,
    terminateProcess,
    waitForProcess,
  )
import System.Process.Internals (ProcessHandle__ (..), withProcessHandle)

-- | SIGTERM grace before escalating to SIGKILL.
termGraceUs :: Int
termGraceUs = 3_000_000

-- | Stop and reap a child process, from any state:
--
--   1. already exited → 'getProcessExitCode' has (or 'waitForProcess'
--      will) reaped it, nothing else to do;
--   2. running → SIGTERM, wait 'termGraceUs';
--   3. still running → SIGKILL (unblockable, so the final
--      'waitForProcess' always returns).
--
-- Safe as a 'bracket' release and safe to call after the child was
-- already waited on ('waitForProcess' returns the cached exit code).
reapProcess :: ProcessHandle -> IO ()
reapProcess ph = uninterruptibleMask_ $ do
  alive <- isNothing <$> getProcessExitCode ph
  when alive $ do
    void (try (terminateProcess ph) :: IO (Either SomeException ()))
    exited <- pollGrace termGraceUs
    unless exited (killSig ph)
  void (waitForProcess ph)
  where
    -- Poll for exit across the grace window so a promptly-dying child
    -- doesn't cost the whole 3 s.
    pollGrace budget
      | budget <= 0 = pure False
      | otherwise = do
          mEc <- getProcessExitCode ph
          case mEc of
            Just _ -> pure True
            Nothing -> threadDelay 100_000 >> pollGrace (budget - 100_000)

-- | SIGKILL via the unix package — @process-1.6.26@ exports no
-- 'killProcess'. ESRCH (child raced us to exit) is fine, the final
-- 'waitForProcess' reaps either way.
killSig :: ProcessHandle -> IO ()
killSig ph =
  void $ withProcessHandle ph $ \p -> case p of
    OpenHandle pid -> do
      void (try (Sig.signalProcess Sig.sigKILL pid) :: IO (Either SomeException ()))
      pure (p, ())
    _ -> pure (p, ())
