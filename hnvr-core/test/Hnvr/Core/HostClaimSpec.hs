{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.HostClaim".
--
-- Pins the arbitration that prevents the 2026-08-15 duplicate-capture
-- bug: an hnvr-node claiming the leader's own host must be denied.
module Hnvr.Core.HostClaimSpec (tests) where

import Hnvr.Core.HostClaim (ClaimDecision (..), decideSnapshotClaim)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.HostClaim"
    [ testCase "foreign host request is granted" $
        decideSnapshotClaim "hnvr-2" False "hnvr-1" @?= ClaimGranted,
      testCase "leader's own request for its host is granted" $
        decideSnapshotClaim "hnvr-2" True "hnvr-2" @?= ClaimGranted,
      testCase "external node claiming the leader's host is denied" $
        decideSnapshotClaim "hnvr-2" False "hnvr-2" @?= ClaimDeniedLeaderHost,
      testCase "leader flag for a foreign host is still granted" $
        decideSnapshotClaim "hnvr-2" True "hnvr-1" @?= ClaimGranted
    ]
