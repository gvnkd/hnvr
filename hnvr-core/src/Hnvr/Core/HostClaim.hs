{-# LANGUAGE DerivingStrategies #-}

-- | Duplicate-worker arbitration for snapshot claims.
--
-- The leader binary runs the full node role for its own host
-- (@01-architecture.md@: "leader = all of node + leader roles"), so an
-- @hnvr-node@ started with the same @HNVR_HOST@ double-records every
-- camera (two RTSP sessions, two fragment uploads a few ms apart;
-- the archive playlist then serves each second of video twice and the
-- player jumps back at every seam — observed on dev 2026-08-15).
--
-- The snapshot request/reply is the arbiter: the leader knows its own
-- host and marks its own bootstrap request with @leader: true@; any
-- other request for the leader's host is denied. Two remote nodes
-- sharing a host are NOT caught (the responder can't distinguish
-- them) — that's a misconfiguration guard for the leader host only.
module Hnvr.Core.HostClaim
  ( ClaimDecision (..),
    decideSnapshotClaim,
  )
where

import Data.Text (Text)

data ClaimDecision = ClaimGranted | ClaimDeniedLeaderHost
  deriving stock (Eq, Show)

-- | @decideSnapshotClaim leaderHost isLeaderRequester requestHost@.
-- The leader's own request (marked @leader: true@ in the payload) is
-- always granted; requests for other hosts are granted; anything else
-- targeting the leader's host is denied.
decideSnapshotClaim :: Text -> Bool -> Text -> ClaimDecision
decideSnapshotClaim leaderHost isLeaderRequester requestHost
  | requestHost == leaderHost && not isLeaderRequester = ClaimDeniedLeaderHost
  | otherwise = ClaimGranted
