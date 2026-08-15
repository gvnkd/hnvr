{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Capture.RingBuffer" — the time-bounded fragment
-- buffer backing event-clip assembly.
module Hnvr.Capture.RingBufferSpec (tests) where

import qualified Data.ByteString.Char8 as BSC
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), addUTCTime)
import Hnvr.Capture.RingBuffer
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))
import Test.Tasty.QuickCheck (testProperty)

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 8 15) 0

at :: Double -> UTCTime
at s = addUTCTime (realToFrac s) t0

frag :: Double -> RingEntry
frag s = RingEntry (at s) (BSC.pack ("frag@" <> show s))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Capture.RingBuffer"
    [ testCase "push appends ascending, entries readable back" $ do
        let rb = push (at 1) "a" . push (at 0) "z" $ empty 10
        map reStart (entries rb) @?= [at 0, at 1],
      testCase "push prunes entries older than window relative to newest" $ do
        let rb = push (at 10) "new" . push (at 5) "mid" . push (at 0) "old" $ empty 6
        -- window 6s from newest (t=10): cutoff t=4, so t=0 drops, t=5 stays
        map reStart (entries rb) @?= [at 5, at 10],
      testCase "entry exactly at the cutoff is kept" $ do
        let rb = push (at 10) "new" . push (at 4) "edge" $ empty 6
        map reStart (entries rb) @?= [at 4, at 10],
      testCase "out-of-order push: prune is relative to the pushed ts" $ do
        let rb = push (at 0) "late" . push (at 10) "new" $ empty 6
        -- pushing t=0 after t=10 prunes relative to t=0 → t=10 survives
        -- (it is newer than cutoff t=-6); both remain.
        map reStart (entries rb) @?= [at 10, at 0],
      testCase "window selects [from,to] inclusively" $ do
        let rb =
              push (at 8) "h"
                . push (at 6) "g"
                . push (at 5) "f"
                . push (at 3) "e"
                . push (at 1) "d"
                $ empty 60
        map reStart (window (at 3) (at 6) rb) @?= [at 3, at 5, at 6],
      testCase "window on empty buffer → []" $
        window (at 0) (at 9) (empty 10) @?= [],
      testCase "init segment: absent until set, then sticks across pushes" $ do
        let rb0 = empty 10
        initBytes rb0 @?= Nothing
        let rb1 = push (at 1) "a" (setInit "init" rb0)
        initBytes rb1 @?= Just "init",
      testProperty "monotonic pushes: all entries within windowSec of the latest" $ \off ->
        let base = abs (off :: Int) `mod` 100_000
            pushes = [fromIntegral base + fromIntegral i * 0.7 | i <- [0 .. 49 :: Int]]
            rb = foldl (\b s -> push (at s) "x" b) (empty 30) pushes
            latest = maximum (map reStart (entries rb))
            cutoff = addUTCTime (-30) latest
         in all (\e -> reStart e >= cutoff) (entries rb)
    ]
