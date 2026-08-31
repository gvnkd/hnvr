{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Cv.Rules" — geometry goldens + rule evaluation
-- semantics (direction, class filter, cooldown, zone transitions).
module Hnvr.Cv.RulesSpec (tests) where

import Data.Aeson (Value, object, (.=))
import qualified Data.Map.Strict as M
import Data.Maybe (isJust, isNothing)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), addUTCTime, secondsToDiffTime)
import Hnvr.Core.CameraSnapshot (RuleSnapshot (..))
import Hnvr.Core.Geometry (Box (..), V2 (..))
import Hnvr.Cv.Rules
  ( Direction (..),
    EngineState (..),
    Rule (..),
    RuleEvent (..),
    RuleEventKind (..),
    RuleState (..),
    ZoneMode (..),
    boxCenter,
    emptyEngineState,
    emptyRuleState,
    evalRule,
    evalTracks,
    pointInPoly,
    projectRule,
    segIntersect,
  )
import Hnvr.Cv.Tracker.Kalman (initKalman)
import Hnvr.Cv.Tracker.Sort (Track (..), TrackId (..))
import Test.QuickCheck (Property, choose, forAll, (===))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Test.Tasty.QuickCheck (testProperty)

t0 :: UTCTime
t0 = UTCTime (fromGregorian 2026 8 13) (secondsToDiffTime 0)

line :: (V2 Double, V2 Double) -> Direction -> Rule
line l dir =
  LineRule
    { rId = "r1",
      rLine = l,
      rDirection = dir,
      rClasses = const True,
      rCooldownMs = 5000
    }

squareZone :: ZoneMode -> Rule
squareZone mode =
  ZoneRule
    { rId = "z1",
      rZone = [V2 (0.2, 0.2), V2 (0.8, 0.2), V2 (0.8, 0.8), V2 (0.2, 0.8)],
      rMode = mode,
      rClasses = const True,
      rCooldownMs = 5000
    }

tests :: TestTree
tests =
  testGroup
    "Hnvr.Cv.Rules"
    [ testGroup
        "boxCenter"
        [ testCase "center of unit box" $ do
            let V2 (cx, cy) = boxCenter (Box 0.2 0.4 0.2 0.2 :: Box Double)
            assertBool "x" (abs (cx - 0.3) < 1e-12)
            assertBool "y" (abs (cy - 0.5) < 1e-12)
        ],
      testGroup
        "segIntersect"
        [ testCase "crossing segments" $
            segIntersect (V2 (0, 0)) (V2 (1, 1)) (V2 (0, 1)) (V2 (1, 0)) @?= True,
          testCase "parallel non-crossing" $
            segIntersect (V2 (0, 0)) (V2 (1, 0)) (V2 (0, 1)) (V2 (1, 1)) @?= False,
          testCase "endpoint touch counts" $
            segIntersect (V2 (0, 0)) (V2 (1, 0)) (V2 (1, 0)) (V2 (2, 2)) @?= True,
          testCase "disjoint" $
            segIntersect (V2 (0, 0)) (V2 (0.1, 0.1)) (V2 (0.5, 0.5)) (V2 (1, 1)) @?= False
        ],
      testGroup
        "pointInPoly"
        [ testCase "inside square" $
            pointInPoly (V2 (0.5, 0.5)) sq @?= True,
          testCase "outside square" $
            pointInPoly (V2 (0.9, 0.5)) sq @?= False,
          testCase "edge counts as inside" $
            pointInPoly (V2 (0.2, 0.5)) sq @?= True,
          testCase "concave polygon: inside the dent" $
            pointInPoly (V2 (0.5, 0.55)) concave @?= False,
          testCase "concave polygon: inside body" $
            pointInPoly (V2 (0.3, 0.5)) concave @?= True
        ],
      testGroup
        "line rule"
        [ testCase "cross in matching direction fires" $ do
            -- horizontal line y=0.5, motion downward at x=0.5
            let r = line (V2 (0, 0.5), V2 (1, 0.5)) DirPositive
                (mEv, _) = evalRule r 0 t0 (V2 (0.5, 0.4)) (V2 (0.5, 0.6)) emptyRuleState
            fmap reKind mEv @?= Just LineCrossed,
          testCase "cross in opposite direction suppressed" $ do
            let r = line (V2 (0, 0.5), V2 (1, 0.5)) DirNegative
                (mEv, _) = evalRule r 0 t0 (V2 (0.5, 0.4)) (V2 (0.5, 0.6)) emptyRuleState
            mEv @?= Nothing,
          testCase "DirAny fires both ways" $ do
            let r = line (V2 (0, 0.5), V2 (1, 0.5)) DirAny
                (mEv1, _) = evalRule r 0 t0 (V2 (0.5, 0.4)) (V2 (0.5, 0.6)) emptyRuleState
                (mEv2, _) = evalRule r 0 t0 (V2 (0.5, 0.6)) (V2 (0.5, 0.4)) emptyRuleState
            assertBool "both directions" (isJust mEv1 && isJust mEv2),
          testCase "no crossing: motion along the line" $ do
            let r = line (V2 (0, 0.5), V2 (1, 0.5)) DirAny
                (mEv, _) = evalRule r 0 t0 (V2 (0.3, 0.5)) (V2 (0.7, 0.5)) emptyRuleState
            mEv @?= Nothing,
          testCase "class filter suppresses" $ do
            let r = (line (V2 (0, 0.5), V2 (1, 0.5)) DirAny) {rClasses = (== 2)}
                (mEv, _) = evalRule r 0 t0 (V2 (0.5, 0.4)) (V2 (0.5, 0.6)) emptyRuleState
            mEv @?= Nothing,
          testCase "cooldown suppresses immediate re-fire" $ do
            let r = line (V2 (0, 0.5), V2 (1, 0.5)) DirAny
                (mEv1, st1) = evalRule r 0 t0 (V2 (0.5, 0.4)) (V2 (0.5, 0.6)) emptyRuleState
                (mEv2, _) = evalRule r 0 (plus 1 t0) (V2 (0.5, 0.6)) (V2 (0.5, 0.4)) st1
            assertBool "first fires" (isJust mEv1)
            mEv2 @?= Nothing,
          testCase "cooldown elapsed: fires again" $ do
            let r = line (V2 (0, 0.5), V2 (1, 0.5)) DirAny
                (_, st1) = evalRule r 0 t0 (V2 (0.5, 0.4)) (V2 (0.5, 0.6)) emptyRuleState
                (mEv2, _) = evalRule r 0 (plus 6 t0) (V2 (0.5, 0.6)) (V2 (0.5, 0.4)) st1
            fmap reKind mEv2 @?= Just LineCrossed
        ],
      testGroup
        "zone rule"
        [ testCase "enter fires on first inside observation" $ do
            let (mEv, st) = evalRule (squareZone ZoneEnter) 0 t0 (V2 (0.1, 0.5)) (V2 (0.5, 0.5)) emptyRuleState
            fmap reKind mEv @?= Just ZoneEntered
            rsInside st @?= Just True,
          testCase "enter does not re-fire while staying inside" $ do
            let (_, st1) = evalRule (squareZone ZoneEnter) 0 t0 (V2 (0.1, 0.5)) (V2 (0.5, 0.5)) emptyRuleState
                (mEv2, _) = evalRule (squareZone ZoneEnter) 0 (plus 10 t0) (V2 (0.5, 0.5)) (V2 (0.6, 0.5)) st1
            mEv2 @?= Nothing,
          testCase "exit fires on leaving" $ do
            let (_, st1) = evalRule (squareZone ZoneEnter) 0 t0 (V2 (0.1, 0.5)) (V2 (0.5, 0.5)) emptyRuleState
                (mEv2, st2) = evalRule (squareZone ZoneExit) 0 (plus 10 t0) (V2 (0.5, 0.5)) (V2 (0.9, 0.5)) st1
            fmap reKind mEv2 @?= Just ZoneExited
            rsInside st2 @?= Just False,
          testCase "inside mode fires repeatedly with cooldown" $ do
            let (mEv1, st1) = evalRule (squareZone ZoneInside) 0 t0 (V2 (0.5, 0.5)) (V2 (0.5, 0.5)) emptyRuleState
                (mEv2, _) = evalRule (squareZone ZoneInside) 0 (plus 1 t0) (V2 (0.5, 0.5)) (V2 (0.5, 0.5)) st1
                (mEv3, _) = evalRule (squareZone ZoneInside) 0 (plus 6 t0) (V2 (0.5, 0.5)) (V2 (0.5, 0.5)) st1
            assertBool "first" (isJust mEv1)
            assertBool "cooldown blocks" (isNothing mEv2)
            assertBool "elapsed fires" (isJust mEv3)
        ],
      testGroup
        "zone motion rule"
        [ testCase "first inside observation anchors, no fire" $ do
            let (mEv, st) = evalRule motionRule 0 t0 (V2 (0.1, 0.5)) (V2 (0.5, 0.5)) emptyRuleState
            mEv @?= Nothing
            rsAnchor st @?= Just (V2 (0.5, 0.5)),
          testCase "stationary jitter below threshold never fires" $ do
            let (_, st1) = evalRule motionRule 0 t0 (V2 (0.5, 0.5)) (V2 (0.5, 0.5)) emptyRuleState
                (mEv2, st2) = evalRule motionRule 0 (plus 10 t0) (V2 (0.5, 0.5)) (V2 (0.52, 0.5)) st1
                (mEv3, _) = evalRule motionRule 0 (plus 20 t0) (V2 (0.52, 0.5)) (V2 (0.49, 0.5)) st2
            mEv2 @?= Nothing
            mEv3 @?= Nothing,
          testCase "displacement beyond threshold fires" $ do
            let (_, st1) = evalRule motionRule 0 t0 (V2 (0.5, 0.5)) (V2 (0.5, 0.5)) emptyRuleState
                (mEv, _) = evalRule motionRule 0 (plus 1 t0) (V2 (0.5, 0.5)) (V2 (0.56, 0.5)) st1
            fmap reKind mEv @?= Just ZoneMotionEvent,
          testCase "slow drift accumulates across frames" $ do
            let (_, st1) = evalRule motionRule 0 t0 (V2 (0.5, 0.5)) (V2 (0.5, 0.5)) emptyRuleState
                (mEv2, st2) = evalRule motionRule 0 (plus 1 t0) (V2 (0.5, 0.5)) (V2 (0.53, 0.5)) st1
                (mEv3, _) = evalRule motionRule 0 (plus 2 t0) (V2 (0.53, 0.5)) (V2 (0.56, 0.5)) st2
            mEv2 @?= Nothing
            fmap reKind mEv3 @?= Just ZoneMotionEvent,
          testCase "re-anchors after firing: no refire while stationary" $ do
            let (_, st1) = evalRule motionRule 0 t0 (V2 (0.5, 0.5)) (V2 (0.5, 0.5)) emptyRuleState
                (mEv2, st2) = evalRule motionRule 0 (plus 1 t0) (V2 (0.5, 0.5)) (V2 (0.56, 0.5)) st1
                (mEv3, _) = evalRule motionRule 0 (plus 10 t0) (V2 (0.56, 0.5)) (V2 (0.56, 0.5)) st2
            assertBool "fires" (isJust mEv2)
            mEv3 @?= Nothing,
          testCase "leaving the zone resets the anchor" $ do
            let (_, st1) = evalRule motionRule 0 t0 (V2 (0.5, 0.5)) (V2 (0.5, 0.5)) emptyRuleState
                (_, st2) = evalRule motionRule 0 (plus 1 t0) (V2 (0.5, 0.5)) (V2 (0.9, 0.5)) st1
                (mEv, st3) = evalRule motionRule 0 (plus 2 t0) (V2 (0.9, 0.5)) (V2 (0.5, 0.5)) st2
            rsAnchor st2 @?= Nothing
            mEv @?= Nothing
            rsAnchor st3 @?= Just (V2 (0.5, 0.5)),
          testCase "movement outside the zone never fires" $ do
            let (mEv, _) = evalRule motionRule 0 t0 (V2 (0.85, 0.5)) (V2 (0.95, 0.5)) emptyRuleState
            mEv @?= Nothing
        ],
      testGroup
        "evalTracks track memory"
        [ testCase "cooldown survives a one-frame dropout" $ do
            let r = squareZone ZoneInside
                (st1, evs1) = evalTracks emptyEngineState [r] 1 1 [mkTrack 7 0 (0.5, 0.5)] t0
                (st2, evs2) = evalTracks st1 [r] 1 1 [] (plus 0.2 t0)
                (_, evs3) = evalTracks st2 [r] 1 1 [mkTrack 7 0 (0.5, 0.5)] (plus 1 t0)
            length evs1 @?= 1
            assertBool "no tracks, no events" (null evs2)
            -- without grace pruning the dropout would have reset the
            -- cooldown and this frame would re-fire
            assertBool "cooldown held across the dropout" (null evs3),
          testCase "id switch adopts the cooldown clock" $ do
            let r = squareZone ZoneInside
                (st1, evs1) = evalTracks emptyEngineState [r] 1 1 [mkTrack 1 0 (0.5, 0.5)] t0
                -- pose change: SORT re-acquires the person as id 2
                (st2, evs2) = evalTracks st1 [r] 1 1 [mkTrack 2 0 (0.52, 0.5)] (plus 0.5 t0)
            length evs1 @?= 1
            assertBool "id switch suppressed by adopted cooldown" (null evs2)
            -- the adopted clock really started at the first fire:
            -- once the cooldown elapses the same track fires again
            let (_, evs3) = evalTracks st2 [r] 1 1 [mkTrack 2 0 (0.52, 0.5)] (plus 6 t0)
            length evs3 @?= 1,
          testCase "no adoption when the fresh track is too far" $ do
            let r = squareZone ZoneInside
                (st1, evs1) = evalTracks emptyEngineState [r] 1 1 [mkTrack 1 0 (0.3, 0.3)] t0
                (st2, evs2) = evalTracks st1 [r] 1 1 [mkTrack 2 0 (0.7, 0.7)] (plus 0.5 t0)
            length evs1 @?= 1
            -- no adoption: both tracks keep their own rule state
            assertBool "track 1 state kept" (M.member ("z1", 1) (esRules st2))
            assertBool "track 2 own state" (M.member ("z1", 2) (esRules st2))
            -- ...but the rule-level refractory suppresses the fresh
            -- track's emit anyway (same rule, 0.5 s after the last)
            assertBool "refractory suppresses" (null evs2)
            -- once the rule cooldown elapses the far track fires on
            -- its own clock
            let (_, evs3) = evalTracks st2 [r] 1 1 [mkTrack 2 0 (0.7, 0.7)] (plus 6 t0)
            length evs3 @?= 1,
          testCase "no adoption across detection classes" $ do
            let r = squareZone ZoneInside
                (st1, evs1) = evalTracks emptyEngineState [r] 1 1 [mkTrack 1 0 (0.5, 0.5)] t0
                (st2, evs2) = evalTracks st1 [r] 1 1 [mkTrack 2 2 (0.51, 0.5)] (plus 0.5 t0)
            length evs1 @?= 1
            assertBool "track 1 state kept" (M.member ("z1", 1) (esRules st2))
            assertBool "track 2 own state" (M.member ("z1", 2) (esRules st2))
            assertBool "refractory suppresses" (null evs2),
          testCase "memory expiry prunes the state" $ do
            let r = squareZone ZoneInside
                (st1, evs1) = evalTracks emptyEngineState [r] 1 1 [mkTrack 5 0 (0.5, 0.5)] t0
                (st2, _) = evalTracks st1 [r] 1 1 [] (plus 12 t0)
                (_, evs3) = evalTracks st2 [r] 1 1 [mkTrack 5 0 (0.5, 0.5)] (plus 12.5 t0)
            length evs1 @?= 1
            -- 12 s gone > 10 s memory: the same id is treated as new
            length evs3 @?= 1,
          testCase "zone motion anchor is adopted on id switch" $ do
            let r = motionRule
                (st1, evs1) = evalTracks emptyEngineState [r] 1 1 [mkTrack 1 0 (0.5, 0.5)] t0
                (st2, evs2) = evalTracks st1 [r] 1 1 [mkTrack 2 0 (0.51, 0.5)] (plus 0.5 t0)
                -- 0.055 from the adopted anchor (0.50) fires; from a
                -- fresh anchor (0.51) it would be 0.045 — below 0.05
                (_, evs3) = evalTracks st2 [r] 1 1 [mkTrack 2 0 (0.555, 0.5)] (plus 1 t0)
            assertBool "anchor only" (null evs1)
            assertBool "adopted anchor, small step" (null evs2)
            length evs3 @?= 1,
          testCase "live duplicate is shadowed and inherits on primary death" $ do
            let r = squareZone ZoneInside
                (st1, evs1) = evalTracks emptyEngineState [r] 1 1 [mkTrack 1 0 (0.5, 0.5)] t0
                -- duplicate detection of the same person confirms as
                -- track 2 while track 1 is still live
                (st2, evs2) = evalTracks st1 [r] 1 1 [mkTrack 1 0 (0.5, 0.5), mkTrack 2 0 (0.6, 0.5)] (plus 0.5 t0)
                -- primary dies: the shadow inherits its cooldown
                -- clock instead of re-firing as a fresh track
                (_, evs3) = evalTracks st2 [r] 1 1 [mkTrack 2 0 (0.6, 0.5)] (plus 1 t0)
            length evs1 @?= 1
            assertBool "shadow not evaluated, primary in cooldown" (null evs2)
            assertBool "inherited cooldown suppresses refire" (null evs3),
          testCase "different class live track does not shadow" $ do
            let r = squareZone ZoneInside
                (st1, evs1) = evalTracks emptyEngineState [r] 1 1 [mkTrack 1 0 (0.5, 0.5)] t0
                (st2, evs2) = evalTracks st1 [r] 1 1 [mkTrack 1 0 (0.5, 0.5), mkTrack 2 2 (0.55, 0.5)] (plus 0.5 t0)
            length evs1 @?= 1
            assertBool "not shadowed" (M.notMember 2 (esShadows st2))
            assertBool "refractory suppresses" (null evs2),
          testCase "far live track does not shadow" $ do
            let r = squareZone ZoneInside
                (st1, evs1) = evalTracks emptyEngineState [r] 1 1 [mkTrack 1 0 (0.5, 0.5)] t0
                (st2, evs2) = evalTracks st1 [r] 1 1 [mkTrack 1 0 (0.5, 0.5), mkTrack 2 0 (0.75, 0.75)] (plus 0.5 t0)
            length evs1 @?= 1
            assertBool "not shadowed" (M.notMember 2 (esShadows st2))
            assertBool "refractory suppresses" (null evs2),
          testCase "shadow split re-arms the second track" $ do
            let r = squareZone ZoneInside
                (st1, evs1) = evalTracks emptyEngineState [r] 1 1 [mkTrack 1 0 (0.5, 0.5)] t0
                (st2, evs2) = evalTracks st1 [r] 1 1 [mkTrack 1 0 (0.5, 0.5), mkTrack 2 0 (0.6, 0.5)] (plus 0.5 t0)
                -- the pair diverges beyond shadow range: two objects
                -- after all — the mapping drops and the second track
                -- is evaluated, but the rule-level refractory (1 s
                -- after the last emit) still holds the emit
                (st3, evs3) = evalTracks st2 [r] 1 1 [mkTrack 1 0 (0.5, 0.5), mkTrack 2 0 (0.75, 0.75)] (plus 1 t0)
                -- once the rule cooldown elapses the pair fires once
                -- more (refractory: one emit per rule per window)
                (_, evs4) = evalTracks st3 [r] 1 1 [mkTrack 1 0 (0.5, 0.5), mkTrack 2 0 (0.75, 0.75)] (plus 6.5 t0)
            length evs1 @?= 1
            assertBool "shadowed" (null evs2)
            assertBool "mapping dropped" (M.null (esShadows st3))
            assertBool "refractory suppresses" (null evs3)
            length evs4 @?= 1,
          testCase "velocity prediction adopts a walking person" $ do
            let r = squareZone ZoneInside
                (st1, evs1) = evalTracks emptyEngineState [r] 1 1 [mkTrack 1 0 (0.4, 0.5)] t0
                -- second frame establishes the velocity (0.1/s to the right)
                (st2, _) = evalTracks st1 [r] 1 1 [mkTrack 1 0 (0.45, 0.5)] (plus 0.5 t0)
                -- 3 s later the person is re-acquired as id 2 at
                -- (0.74, 0.5): 0.29 from the last SEEN position (no
                -- adoption without prediction) but 0.01 from the
                -- extrapolated (0.75, 0.5)
                (_, evs3) = evalTracks st2 [r] 1 1 [mkTrack 2 0 (0.74, 0.5)] (plus 3.5 t0)
            length evs1 @?= 1
            assertBool "adopted cooldown suppresses refire" (null evs3),
          testCase "donor older than 3 s is still adoptable" $ do
            -- regression: trackMemorySec must exceed the adoption
            -- window — a 3 s memory trimmed donors before a 5 s
            -- window could match them (the 13:04 triple)
            let r = (squareZone ZoneInside) {rCooldownMs = 15000}
                (st1, evs1) = evalTracks emptyEngineState [r] 1 1 [mkTrack 1 0 (0.3, 0.25)] t0
                (st2, _) = evalTracks st1 [r] 1 1 [] (plus 1 t0)
                (_, evs3) = evalTracks st2 [r] 1 1 [mkTrack 2 0 (0.31, 0.24)] (plus 5.5 t0)
            length evs1 @?= 1
            assertBool "5.5 s gap, same spot: adopted, no refire" (null evs3),
          testCase "long occlusion: velocity prediction carries across 6 s" $ do
            -- the 13:05 case: person walks ~0.47 normalized in 6.6 s —
            -- far beyond any static radius, but right where the
            -- velocity extrapolation points
            let r = (squareZone ZoneInside) {rCooldownMs = 15000}
                (st1, evs1) = evalTracks emptyEngineState [r] 1 1 [mkTrack 2 0 (0.3, 0.25)] t0
                (st2, _) = evalTracks st1 [r] 1 1 [mkTrack 2 0 (0.35, 0.3)] (plus 1 t0)
                -- v = (0.05, 0.05)/s; donor last seen at t0+1;
                -- 6 s later predicted at (0.65, 0.60)
                (_, evs3) = evalTracks st2 [r] 1 1 [mkTrack 4 0 (0.645, 0.605)] (plus 7 t0)
            length evs1 @?= 1
            assertBool "adopted via prediction" (null evs3)
        ],
      testGroup
        "rule-level refractory"
        [ testCase "id-churn burst collapses to one event per window" $ do
            -- the whole-frame zone_inside storm: SORT hands the same
            -- person a new id every few frames and adoption can't
            -- match the scattered reappearances — without the
            -- refractory every orphan id fired on first observation
            let r = squareZone ZoneInside
                (st1, evs1) = evalTracks emptyEngineState [r] 1 1 [mkTrack 1 0 (0.3, 0.3)] t0
                (st2, evs2) = evalTracks st1 [r] 1 1 [mkTrack 2 0 (0.7, 0.3)] (plus 1 t0)
                (st3, evs3) = evalTracks st2 [r] 1 1 [mkTrack 3 0 (0.3, 0.7)] (plus 2 t0)
                (st4, evs4) = evalTracks st3 [r] 1 1 [mkTrack 4 0 (0.7, 0.7)] (plus 3 t0)
                (_, evs5) = evalTracks st4 [r] 1 1 [mkTrack 5 0 (0.5, 0.5)] (plus 6 t0)
            length evs1 @?= 1
            assertBool "burst suppressed" (null evs2 && null evs3 && null evs4)
            length evs5 @?= 1,
          testCase "refractory is per rule" $ do
            let r1 = squareZone ZoneInside
                r2 = (squareZone ZoneInside) {rId = "z2"}
                (st1, evs1) = evalTracks emptyEngineState [r1] 1 1 [mkTrack 1 0 (0.5, 0.5)] t0
                -- r2 (hot-added) has never emitted: its gate is open
                -- even though r1 fired 1 s ago
                (_, evs2) = evalTracks st1 [r1, r2] 1 1 [mkTrack 2 0 (0.7, 0.7)] (plus 1 t0)
            length evs1 @?= 1
            length evs2 @?= 1
            map (reRuleId . (\(_, _, ev) -> ev)) evs2 @?= ["z2"],
          testCase "refractory window follows the rule's cooldown" $ do
            let r = (squareZone ZoneInside) {rCooldownMs = 15000}
                (st1, evs1) = evalTracks emptyEngineState [r] 1 1 [mkTrack 1 0 (0.5, 0.5)] t0
                (st2, evs2) = evalTracks st1 [r] 1 1 [mkTrack 2 0 (0.7, 0.7)] (plus 6 t0)
                (_, evs3) = evalTracks st2 [r] 1 1 [mkTrack 3 0 (0.3, 0.3)] (plus 16 t0)
            length evs1 @?= 1
            assertBool "6 s < 15 s cooldown: suppressed" (null evs2)
            length evs3 @?= 1
        ],
      testGroup
        "projectRule zone_motion"
        [ testCase "parses min_displacement" $
            motionSnap (Just 0.1) @?= Just (ZoneMotion 0.1),
          testCase "missing min_displacement defaults to 0.03" $
            motionSnap Nothing @?= Just (ZoneMotion 0.03),
          testCase "out-of-range min_displacement defaults" $
            motionSnap (Just 1.5) @?= Just (ZoneMotion 0.03),
          testCase "bad polygon rejected" $
            assertBool "rejected" (isNothing (projectRule (motionSnapRaw (object ["polygon" .= [[0.1, 0.1 :: Double]]]))))
        ],
      testProperty "segIntersect is symmetric" prop_segSym,
      testProperty "pointInPoly agrees with bounds check on square" prop_squareSanity
    ]
  where
    sq = [V2 (0.2, 0.2), V2 (0.8, 0.2), V2 (0.8, 0.8), V2 (0.2, 0.8)]
    -- arrow shape: dent at (0.5, 0.5)
    concave = [V2 (0, 0), V2 (1, 0), V2 (1, 1), V2 (0.5, 0.5), V2 (0, 1)]
    plus = addUTCTime
    motionRule = squareZone (ZoneMotion 0.05)
    -- A track whose box is centered at the given normalized point
    -- (frame dims are 1×1 in these tests, so norm is the identity).
    mkTrack :: Int -> Int -> (Float, Float) -> Track
    mkTrack tid cls (cx, cy) =
      let b = Box (cx - 0.05) (cy - 0.05) 0.1 0.1
       in Track
            { tId = TrackId tid,
              tBox = b,
              tPrevBox = b,
              tClassId = cls,
              tScore = 0.9,
              tHits = 5,
              tTimeSinceUpdate = 0,
              tAge = 5,
              tKalman = initKalman b
            }
    motionSnap :: Maybe Double -> Maybe ZoneMode
    motionSnap mThr =
      case projectRule (motionSnapRaw (motionGeo mThr)) of
        Just ZoneRule {rMode = m} -> Just m
        _ -> Nothing
    motionSnapRaw geo =
      RuleSnapshot
        { rsId = "z1",
          rsKind = "zone_motion",
          rsGeometry = geo,
          rsClasses = [0],
          rsCooldownMs = 5000,
          rsClipPrerollSec = 5,
          rsClipPostrollSec = 5,
          rsClipRetentionHours = Nothing
        }
    motionGeo :: Maybe Double -> Value
    motionGeo mThr =
      object
        ( ("polygon" .= ([[0.2, 0.2], [0.8, 0.2], [0.8, 0.8], [0.2, 0.8]] :: [[Double]]))
            : maybe [] (\d -> ["min_displacement" .= d]) mThr
        )

prop_segSym :: Property
prop_segSym =
  forAll (choose (0, 1)) $ \x1 ->
    forAll (choose (0, 1)) $ \y1 ->
      forAll (choose (0, 1)) $ \x2 ->
        forAll (choose (0, 1)) $ \y2 ->
          forAll (choose (0, 1)) $ \x3 ->
            forAll (choose (0, 1)) $ \y3 ->
              forAll (choose (0, 1)) $ \x4 ->
                forAll (choose (0, 1)) $ \y4 ->
                  segIntersect (V2 (x1, y1)) (V2 (x2, y2)) (V2 (x3, y3)) (V2 (x4, y4))
                    === segIntersect (V2 (x3, y3)) (V2 (x4, y4)) (V2 (x1, y1)) (V2 (x2, y2))

prop_squareSanity :: Property
prop_squareSanity =
  forAll (choose (0, 1)) $ \px ->
    forAll (choose (0, 1)) $ \py ->
      pointInPoly (V2 (px, py)) sq === insideBounds px py
  where
    sq = [V2 (0.2, 0.2), V2 (0.8, 0.2), V2 (0.8, 0.8), V2 (0.2, 0.8)]
    insideBounds px py = px >= 0.2 && px <= 0.8 && py >= 0.2 && py <= 0.8
