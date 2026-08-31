{-# LANGUAGE NumericUnderscores #-}

-- | Regression tests for 'reapProcess' (pitfall #130): a capture worker
-- cancelled while blocked in the stdout read loop must not leave the
-- ffmpeg behind as a zombie.
module Hnvr.Capture.ProcessSpec (tests) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async, cancel)
import Control.Concurrent.MVar (newEmptyMVar, putMVar, takeMVar)
import Control.Exception (bracket)
import Data.Maybe (isJust)
import Hnvr.Capture.Process (reapProcess)
import System.Process
import System.Timeout (timeout)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Capture.Process"
    [ testCase "cancel mid-read reaps the child (no zombie)" $ do
        mv <- newEmptyMVar
        a <-
          async $
            bracket
              (createProcess (proc "sleep" ["30"]))
              (\(_, _, _, ph) -> reapProcess ph)
              (\(_, _, _, ph) -> putMVar mv ph >> threadDelay 60_000_000)
        ph <- takeMVar mv
        -- cancel blocks until the masked bracket release has finished.
        cancel a
        mEc <- getProcessExitCode ph
        assertBool "child was not reaped (zombie)" (isJust mEc),
      testCase "reapProcess on a running child returns before the full grace" $ do
        (_, _, _, ph) <- createProcess (proc "sleep" ["30"])
        m <- timeout 2_000_000 (reapProcess ph)
        assertBool "reapProcess hung" (isJust m)
        mEc <- getProcessExitCode ph
        assertBool "child still running after reapProcess" (isJust mEc),
      testCase "reapProcess on an already-waited child is a no-op" $ do
        (_, _, _, ph) <- createProcess (proc "true" [])
        _ <- waitForProcess ph
        m <- timeout 1_000_000 (reapProcess ph)
        assertBool "reapProcess hung" (isJust m)
    ]
