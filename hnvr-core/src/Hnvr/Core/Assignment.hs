{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure decision logic for camera→host assignment.
--
-- Extracted from @Hnvr.Web.AssignmentCoordinator@ so it can be
-- property-tested without dragging in the IHP-generated @Camera@ record
-- or the @ModelContext@ / @Bus@ IO surface. The web layer unpacks the
-- relevant @Camera@ fields into 'CameraAssignment' and calls
-- 'pickTarget' here.
--
-- Rules (per @design_docs/01-architecture.md@ §"AssignmentCoordinator"):
--
--   * @manual_assign = True@ cameras are pinned to whatever the admin
--     set; we never override.
--   * If the current host is healthy, keep the assignment (anti-flap).
--   * Otherwise reassign to the least-loaded healthy host. v1 picks the
--     lex-smallest id; load-aware assignment lands in a later slice.
module Hnvr.Core.Assignment
  ( CameraAssignment (..),
    AssignmentDecision (..),
    pickTarget,
    leastLoaded,
  )
where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

-- | The subset of a camera row that assignment logic needs. The web
-- layer constructs this from the IHP-generated @Camera@ record so the
-- pure logic here doesn't depend on @Generated.Types@.
data CameraAssignment = CameraAssignment
  { caSlug :: !Text,
    caManualAssign :: !Bool,
    caAssignedHost :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

-- | The decision returned by 'pickTarget'. 'Reassign' carries the new
-- host id; 'Keep' means the current state is fine.
data AssignmentDecision = Keep | Reassign !Text
  deriving stock (Eq, Show)

-- | Decide whether a camera needs reassignment, and to which host.
-- The 'Map' is the set of healthy host ids keyed by host id (the value
-- is whatever timestamp / load info the caller has; we only use the
-- keys here).
pickTarget :: Map Text a -> CameraAssignment -> AssignmentDecision
pickTarget healthy cam
  | caManualAssign cam = Keep
  | otherwise =
      let currentHealthy = maybe False (`Map.member` healthy) (caAssignedHost cam)
       in if currentHealthy
            then Keep
            else Reassign (leastLoaded healthy)

-- | Pick the healthy host with the lex-smallest id. The "keep if
-- healthy" rule prevents flapping; v1 with 2 hosts doesn't need real
-- load balancing. Slice 5b will pass per-host load info here.
--
-- Falls back to @"hnvr-2"@ if the map is empty so the caller can still
-- publish an assignment (matches the historical behaviour — the
-- AssignmentCoordinator skips the whole pass when @null hosts@, but
-- this is defensive in case the check moves).
leastLoaded :: Map Text a -> Text
leastLoaded healthy =
  case Map.keys healthy of
    (h : _) -> h
    [] -> "hnvr-2"
