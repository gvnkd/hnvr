{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Cv.Rules" — geometry goldens + rule evaluation
-- semantics (direction, class filter, cooldown, zone transitions).
module Hnvr.Cv.RulesSpec (tests) where

import Data.Aeson (Value, object, (.=))
import Data.Maybe (isJust, isNothing)
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), addUTCTime, secondsToDiffTime)
import Hnvr.Core.CameraSnapshot (RuleSnapshot (..))
import Hnvr.Core.Geometry (Box (..), V2 (..))
import Hnvr.Cv.Rules
  ( Direction (..),
    Rule (..),
    RuleEvent (..),
    RuleEventKind (..),
    RuleState (..),
    ZoneMode (..),
    boxCenter,
    emptyRuleState,
    evalRule,
    pointInPoly,
    projectRule,
    segIntersect,
  )
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
