{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Line crossing + zone intrusion rules engine (design_docs/04
-- §"Rules engine").
--
-- Pure Haskell. Consumes per-track center movement (previous →
-- current center, normalized 0..1 coords) and emits 'RuleEvent' on
-- transitions only: line crossed in the matching direction, zone
-- entered\/exited\/inside. Per-rule cooldown suppresses re-fires;
-- the per-(track, rule) state is threaded explicitly so the engine
-- stays testable without IO.
--
-- All geometry is /normalized/ image coordinates (0..1) — independent
-- of analysis resolution. The UI draws on a 640×360 still; the
-- analyzer converts track boxes from source pixels with the frame
-- dims.
module Hnvr.Cv.Rules
  ( -- * Rules
    Rule (..),
    Direction (..),
    ZoneMode (..),
    ruleId,
    ruleClasses,
    ruleCooldownMs,

    -- * Per-(track, rule) state
    RuleState (..),
    emptyRuleState,

    -- * Events
    RuleEvent (..),
    RuleEventKind (..),

    -- * Evaluation
    evalRule,
    evalTracks,
    normalizeBox,

    -- * Wire projection
    projectRule,

    -- * Geometry (exported for tests)
    boxCenter,
    segIntersect,
    crossSign,
    pointInPoly,
  )
where

import Data.Aeson (Value (..))
import qualified Data.Aeson.Key as K
import qualified Data.Aeson.KeyMap as KM
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, diffUTCTime)
import qualified Data.Vector as V
import Hnvr.Core.CameraSnapshot (RuleSnapshot (..))
import Hnvr.Core.Geometry (Box (..), V2 (..))
import Hnvr.Cv.Tracker.Sort (Track (..), TrackId (..))

-- | Line-cross direction filter: which side of the line the motion
-- vector must point to (cross product sign of line direction × motion).
data Direction = DirPositive | DirNegative | DirAny
  deriving stock (Eq, Show)

-- | Zone trigger mode (design @rule_kind@ enum). 'ZoneMotion' carries
-- the minimum displacement (normalized 0..1 units) a track must
-- accumulate inside the zone before the rule fires — stationary
-- objects never trigger it.
data ZoneMode = ZoneEnter | ZoneExit | ZoneInside | ZoneMotion !Double
  deriving stock (Eq, Show)

-- | One rule on one camera. @rId@ is the DB primary key rendered as
-- text — the engine doesn't care about the shape.
data Rule
  = LineRule
      { rId :: !Text,
        rLine :: !(V2 Double, V2 Double),
        rDirection :: !Direction,
        rClasses :: Int -> Bool,
        rCooldownMs :: !Int
      }
  | ZoneRule
      { rId :: !Text,
        rZone :: ![V2 Double],
        rMode :: !ZoneMode,
        rClasses :: Int -> Bool,
        rCooldownMs :: !Int
      }

ruleId :: Rule -> Text
ruleId LineRule {rId = i} = i
ruleId ZoneRule {rId = i} = i

ruleClasses :: Rule -> (Int -> Bool)
ruleClasses LineRule {rClasses = c} = c
ruleClasses ZoneRule {rClasses = c} = c

ruleCooldownMs :: Rule -> Int
ruleCooldownMs LineRule {rCooldownMs = c} = c
ruleCooldownMs ZoneRule {rCooldownMs = c} = c

-- | Project a wire 'RuleSnapshot' (raw JSONB geometry, design 06)
-- into a typed 'Rule'. Returns 'Nothing' on malformed geometry or an
-- unknown kind — a bad rule row must not kill the analyzer; the caller
-- logs the drop. Line: @{ "a": [x,y], "b": [x,y], "direction":
-- "positive"|"negative"|"any" }@. Zone: @{ "polygon": [[x,y], ...] }@;
-- @zone_motion@ takes an optional @"min_displacement"@ (normalized,
-- default 3% of the frame).
projectRule :: RuleSnapshot -> Maybe Rule
projectRule snap =
  let classes = (`elem` rsClasses snap)
      cooldown = rsCooldownMs snap
   in case rsKind snap of
        "line_cross" -> do
          a <- pointField "a" (rsGeometry snap)
          b <- pointField "b" (rsGeometry snap)
          dir <- case textField "direction" (rsGeometry snap) of
            Just "positive" -> Just DirPositive
            Just "negative" -> Just DirNegative
            Just "any" -> Just DirAny
            _ -> Just DirAny -- missing/unknown direction defaults to any
          Just
            LineRule
              { rId = rsId snap,
                rLine = (a, b),
                rDirection = dir,
                rClasses = classes,
                rCooldownMs = cooldown
              }
        kind | kind `elem` ["zone_enter", "zone_exit", "zone_inside", "zone_motion"] -> do
          poly <- pointsField "polygon" (rsGeometry snap)
          mode <- case kind of
            "zone_enter" -> Just ZoneEnter
            "zone_exit" -> Just ZoneExit
            "zone_inside" -> Just ZoneInside
            "zone_motion" -> Just (ZoneMotion (motionThreshold (rsGeometry snap)))
            _ -> Nothing
          if length poly < 3
            then Nothing
            else
              Just
                ZoneRule
                  { rId = rsId snap,
                    rZone = poly,
                    rMode = mode,
                    rClasses = classes,
                    rCooldownMs = cooldown
                  }
        _ -> Nothing
  where
    pointField k (Object o) = case KM.lookup (K.fromText k) o of
      Just (Array v)
        | [Number x, Number y] <- V.toList v ->
            Just (V2 (toRealFloat x, toRealFloat y))
      _ -> Nothing
    pointField _ _ = Nothing
    pointsField k (Object o) = case KM.lookup (K.fromText k) o of
      Just (Array vs) -> mapM fromPoint (V.toList vs)
      _ -> Nothing
    pointsField _ _ = Nothing
    fromPoint (Array v)
      | [Number x, Number y] <- V.toList v = Just (V2 (toRealFloat x, toRealFloat y))
    fromPoint _ = Nothing
    textField k (Object o) = case KM.lookup (K.fromText k) o of
      Just (String t) -> Just t
      _ -> Nothing
    textField _ _ = Nothing
    -- \| @min_displacement@ in normalized units; missing or out of
    -- range falls back to 3% of the frame.
    motionThreshold g = case numberField "min_displacement" g of
      Just d | d > 0 && d < 1 -> d
      _ -> defaultMotionThreshold
    numberField k (Object o) = case KM.lookup (K.fromText k) o of
      Just (Number n) -> Just (toRealFloat n)
      _ -> Nothing
    numberField _ _ = Nothing

-- | Default 'ZoneMotion' displacement: 3% of the frame (normalized).
defaultMotionThreshold :: Double
defaultMotionThreshold = 0.03

-- | Per-(track, rule) evaluation state. @rsInside@ is the zone
-- inside/outside edge detector ('Nothing' = no observation yet — the
-- first inside-observation fires Enter, matching the design's
-- transition-only semantics). @rsAnchor@ is the 'ZoneMotion' reference
-- point: the position from which displacement is measured ('Nothing' =
-- track outside the zone or not yet observed inside).
data RuleState = RuleState
  { rsLastEmit :: !(Maybe UTCTime),
    rsInside :: !(Maybe Bool),
    rsAnchor :: !(Maybe (V2 Double))
  }
  deriving stock (Eq, Show)

emptyRuleState :: RuleState
emptyRuleState = RuleState {rsLastEmit = Nothing, rsInside = Nothing, rsAnchor = Nothing}

-- | Event kind emitted by the engine (design @event_kind@ CV subset).
data RuleEventKind = LineCrossed | ZoneEntered | ZoneExited | ZoneInsideEvent | ZoneMotionEvent
  deriving stock (Eq, Show)

data RuleEvent = RuleEvent
  { reRuleId :: !Text,
    reKind :: !RuleEventKind,
    reTs :: !UTCTime
  }
  deriving stock (Eq, Show)

-- | Evaluate one rule for one track movement. Returns the event to
-- emit (if any) and the updated state. The caller supplies the track's
-- previous and current center in normalized coords, the detection
-- class, and the frame timestamp.
evalRule :: Rule -> Int -> UTCTime -> V2 Double -> V2 Double -> RuleState -> (Maybe RuleEvent, RuleState)
evalRule rule classId now p0 p1 st
  | not (ruleClasses rule classId) = (Nothing, st)
  | otherwise = case rule of
      LineRule {rLine = (a, b), rDirection = dir} ->
        let crossed = segIntersect p0 p1 a b && dirMatches dir a b p0 p1
            kind = LineCrossed
         in fire rule kind now crossed st
      ZoneRule {rZone = poly, rMode = ZoneMotion thr} ->
        let insideNow = pointInPoly p1 poly
            st0 = st {rsInside = Just insideNow}
         in if not insideNow
              then (Nothing, st0 {rsAnchor = Nothing})
              else case rsAnchor st of
                Nothing -> (Nothing, st0 {rsAnchor = Just p1})
                Just anchor ->
                  let moved = dist anchor p1 >= thr
                      (mEv, st1) = fire rule ZoneMotionEvent now moved st0
                      -- On emit, re-anchor so the next event needs a
                      -- fresh threshold displacement; while the
                      -- cooldown suppresses, keep accumulating.
                      st2 = maybe st1 (const (st1 {rsAnchor = Just p1})) mEv
                   in (mEv, st2)
      ZoneRule {rZone = poly, rMode = mode} ->
        let insideNow = pointInPoly p1 poly
            transition = case (rsInside st, insideNow, mode) of
              (Just False, True, ZoneEnter) -> True
              (Nothing, True, ZoneEnter) -> True
              (Just True, False, ZoneExit) -> True
              (Just True, True, ZoneInside) -> True
              (Nothing, True, ZoneInside) -> True
              _ -> False
            kind = case mode of
              ZoneEnter -> ZoneEntered
              ZoneExit -> ZoneExited
              ZoneInside -> ZoneInsideEvent
            (mEv, st') = fire rule kind now transition st
         in (mEv, st' {rsInside = Just insideNow})

-- | Evaluate a set of rules over one frame's tracks. Threads the
-- per-(rule, track) cooldown\/zone state via the returned map — the
-- caller stores it (IORef\/TVar) between frames. State entries for
-- tracks that disappeared are pruned (a re-appearing object gets a
-- fresh track id from SORT anyway, so fresh rule state is correct).
--
-- Track boxes are in source-frame pixels; they are normalized with
-- the frame dims before evaluation.
evalTracks ::
  Map (Text, Int) RuleState ->
  [Rule] ->
  -- | Frame width \/ height (source pixels).
  Int ->
  Int ->
  [Track] ->
  UTCTime ->
  (Map (Text, Int) RuleState, [(Rule, Track, RuleEvent)])
evalTracks states rules fw fh tracks now =
  let liveTids = [n | Track {tId = TrackId n} <- tracks]
      pruned = M.filterWithKey (\(_, tid) _ -> tid `elem` liveTids) states
      step (st, evs) track =
        let p0 = norm (boxCenter (tPrevBox track))
            p1 = norm (boxCenter (tBox track))
            stepRule (st', evs') rule =
              let key = (ruleId rule, let TrackId n = tId track in n)
                  prevSt = M.findWithDefault emptyRuleState key st'
                  (mEv, newSt) = evalRule rule (tClassId track) now p0 p1 prevSt
               in ( M.insert key newSt st',
                    maybe evs' (\ev -> (rule, track, ev) : evs') mEv
                  )
         in foldl stepRule (st, evs) rules
      (st', evs) = foldl step (pruned, []) tracks
   in (st', reverse evs)
  where
    norm (V2 (x, y)) =
      V2 (realToFrac x / fromIntegral fw, realToFrac y / fromIntegral fh)

-- | Normalize a source-pixel box to 0..1 coords.
normalizeBox :: Int -> Int -> Box Float -> Box Double
normalizeBox fw fh Box {bxX = x, bxY = y, bxW = w, bxH = h} =
  Box
    { bxX = realToFrac x / fromIntegral fw,
      bxY = realToFrac y / fromIntegral fh,
      bxW = realToFrac w / fromIntegral fw,
      bxH = realToFrac h / fromIntegral fh
    }

-- | Cooldown gate: emit only when the transition fired AND the
-- cooldown since the last emit has elapsed. The cooldown clock resets
-- on every EMITTED event (not on suppressed transitions).
fire :: Rule -> RuleEventKind -> UTCTime -> Bool -> RuleState -> (Maybe RuleEvent, RuleState)
fire _ _ _ False st = (Nothing, st)
fire rule kind now True st =
  let cooldownOk = case rsLastEmit st of
        Nothing -> True
        Just lastEmit ->
          diffUTCTime now lastEmit * 1000 > fromIntegral (ruleCooldownMs rule)
   in if cooldownOk
        then
          ( Just RuleEvent {reRuleId = ruleId rule, reKind = kind, reTs = now},
            st {rsLastEmit = Just now}
          )
        else (Nothing, st)

-- | Direction match: cross product of the line direction (a→b) with
-- the motion vector (p0→p1). Positive cross = motion goes left of the
-- line direction. Collinear motion ALONG the line (cross = 0) is never
-- a crossing, even under 'DirAny'.
dirMatches :: Direction -> V2 Double -> V2 Double -> V2 Double -> V2 Double -> Bool
dirMatches dir a b p0 p1 = case compare (crossSign a b p0 p1) 0 of
  GT -> dir == DirPositive || dir == DirAny
  LT -> dir == DirNegative || dir == DirAny
  EQ -> False

-- | Center of an axis-aligned box.
boxCenter :: (Fractional a) => Box a -> V2 a
boxCenter Box {bxX = x, bxY = y, bxW = w, bxH = h} =
  V2 (x + w / 2, y + h / 2)

-- | Euclidean distance between two points (normalized coords).
dist :: (Floating a) => V2 a -> V2 a -> a
dist (V2 (x1, y1)) (V2 (x2, y2)) =
  sqrt ((x2 - x1) ^ (2 :: Int) + (y2 - y1) ^ (2 :: Int))

-- | Segment-segment intersection test (proper + endpoint touching).
segIntersect :: (Ord a, Fractional a) => V2 a -> V2 a -> V2 a -> V2 a -> Bool
segIntersect (V2 (x1, y1)) (V2 (x2, y2)) (V2 (x3, y3)) (V2 (x4, y4)) =
  let d1 = cross3 x3 y3 x4 y4 x1 y1
      d2 = cross3 x3 y3 x4 y4 x2 y2
      d3 = cross3 x1 y1 x2 y2 x3 y3
      d4 = cross3 x1 y1 x2 y2 x4 y4
   in ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
        && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
        || (d1 == 0 && onSeg x3 y3 x4 y4 x1 y1)
        || (d2 == 0 && onSeg x3 y3 x4 y4 x2 y2)
        || (d3 == 0 && onSeg x1 y1 x2 y2 x3 y3)
        || (d4 == 0 && onSeg x1 y1 x2 y2 x4 y4)
  where
    cross3 ax ay bx by px py = (bx - ax) * (py - ay) - (by - ay) * (px - ax)
    onSeg ax ay bx by px py =
      min ax bx <= px && px <= max ax bx && min ay by <= py && py <= max ay by

-- | Signed cross product of line direction (a→b) × motion (p0→p1).
crossSign :: (Fractional a) => V2 a -> V2 a -> V2 a -> V2 a -> a
crossSign (V2 (ax, ay)) (V2 (bx, by)) (V2 (p0x, p0y)) (V2 (p1x, p1y)) =
  (bx - ax) * (p1y - p0y) - (by - ay) * (p1x - p0x)

-- | Ray-casting point-in-polygon. Points exactly on an edge count as
-- inside (stable across frame-to-frame jitter).
pointInPoly :: (Ord a, Fractional a) => V2 a -> [V2 a] -> Bool
pointInPoly (V2 (px, py)) poly =
  onEdge || odd crossings
  where
    vertices = zip poly (drop 1 poly ++ poly)
    onEdge = any edgeTouch vertices
    crossings = length (filter crosses vertices)
    edgeTouch (V2 (ax, ay), V2 (bx, by)) =
      cross3 ax ay bx by px py == 0
        && min ax bx <= px
        && px <= max ax bx
        && min ay by <= py
        && py <= max ay by
    crosses (V2 (ax, ay), V2 (bx, by)) =
      (ay > py) /= (by > py)
        && px < (bx - ax) * (py - ay) / (by - ay) + ax
    cross3 ax ay bx by cx cy = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
