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
-- The cooldown clock follows the /person/, not the fragile SORT id:
-- 'EngineState' carries a short memory of recently-seen tracks so a
-- detection dropout (pose change → missed frames) doesn't prune the
-- rule state, and a freshly-appearing track that matches a
-- recently-dead one (same class, close, recent) ADOPTS its state —
-- otherwise every tracker id switch would reset the cooldown and
-- re-fire the rule for the same physical object.
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

    -- * Engine state (frame-to-frame)
    EngineState (..),
    SeenTrack (..),
    emptyEngineState,

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
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Scientific (toRealFloat)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime)
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

-- | Last observation of a track: detection class, normalized center,
-- center velocity (normalized units\/s, capped at 'maxTrackVelocity'),
-- frame timestamp. The memory behind grace pruning, id-switch
-- adoption and duplicate shadowing — see 'EngineState'.
data SeenTrack = SeenTrack
  { stClassId :: !Int,
    stCenter :: !(V2 Double),
    stVelocity :: !(V2 Double),
    stLastSeen :: !UTCTime
  }
  deriving stock (Eq, Show)

-- | Per-camera state threaded between frames: per-(rule, track) rule
-- state plus a short memory of recently-seen tracks. The memory makes
-- the cooldown clock follow the physical object rather than the SORT
-- id:
--
--   * /Grace pruning/ — a track missing from a frame (detection
--     dropout, e.g. a pose change) keeps its rule state for
--     'trackMemorySec' instead of losing it on the spot.
--   * /Id-switch adoption/ — SORT hands a re-acquired object a NEW
--     id. A freshly-appearing track whose class matches a
--     recently-dead one (within 'handoverWindowSec') and whose center
--     is within 'handoverRadius' of the dead track's
--     velocity-extrapolated position adopts the dead track's per-rule
--     state (cooldown clock, zone inside flag, motion anchor).
--   * /Duplicate shadowing/ — pose-variant detections slip past NMS
--     and confirm as a SECOND, concurrent SORT track for the same
--     object. A freshly-confirmed track within 'shadowMaxDist' of an
--     already-live same-class track becomes its shadow: it is never
--     rule-evaluated, and when the primary disappears the shadow
--     inherits its rule state (so the person's cooldown still holds).
data EngineState = EngineState
  { esRules :: !(Map (Text, Int) RuleState),
    esSeen :: !(Map Int SeenTrack),
    -- | Shadow track id → primary track id (live duplicates only).
    esShadows :: !(Map Int Int)
  }
  deriving stock (Eq, Show)

emptyEngineState :: EngineState
emptyEngineState = EngineState {esRules = M.empty, esSeen = M.empty, esShadows = M.empty}

-- | Seconds a disappeared track's rule state survives. MUST exceed
-- 'handoverWindowSec' — this trim runs before adoption, so a memory
-- shorter than the adoption window makes older donors unreachable.
-- Sized to outlast the tracker's coast budget (SORT maxAge is 30
-- frames ≈ 6 s at 5 fps analysis) plus re-confirmation latency.
trackMemorySec :: NominalDiffTime
trackMemorySec = 10

-- | Max age of a dead track eligible for id-switch adoption.
handoverWindowSec :: NominalDiffTime
handoverWindowSec = 8

-- | Max distance between a fresh track's center and a dead track's
-- velocity-extrapolated position for adoption (≈20% of the frame).
handoverRadius :: Double
handoverRadius = 0.2

-- | Max center distance between a fresh track and a live one for
-- duplicate shadowing (≈1\/3 of the frame — pose-variant boxes of the
-- same person can be center-shifted that much).
shadowMaxDist :: Double
shadowMaxDist = 0.35

-- | Cap on the stored center velocity (normalized units\/s) so
-- jittery pose-variant centers can't produce absurd extrapolations.
maxTrackVelocity :: Double
maxTrackVelocity = 0.6

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
-- 'EngineState' via the return value — the caller stores it
-- (IORef\/TVar) between frames.
--
-- Track boxes are in source-frame pixels; they are normalized with
-- the frame dims before evaluation.
evalTracks ::
  EngineState ->
  [Rule] ->
  -- | Frame width \/ height (source pixels).
  Int ->
  Int ->
  [Track] ->
  UTCTime ->
  (EngineState, [(Rule, Track, RuleEvent)])
evalTracks st rules fw fh tracks now =
  let -- Forget tracks unseen beyond the memory window.
      seen0 = M.filter (\s -> diffUTCTime now (stLastSeen s) <= trackMemorySec) (esSeen st)
      freshTids = sortOn id [n | n <- liveTids, not (M.member n seen0)]
      -- Shadow bookkeeping. A mapping dies when the shadow disappears;
      -- when only the primary disappears the shadow inherits its rule
      -- state and becomes an ordinary track; mappings whose tracks
      -- have visibly diverged are dropped (two objects that split
      -- re-arm independently).
      (rules0, seen1, shadows0) =
        M.foldlWithKey' inheritStep (esRules st, seen0, M.empty) (esShadows st)
      shadows1 = M.filterWithKey closeLive shadows0
      established0 =
        [ n
        | n <- liveTids,
          M.member n seen1,
          not (M.member n shadows1)
        ]
      -- New duplicates: fresh ids close to an already-live same-class
      -- track become its shadow (nearest primary wins). Fresh ids
      -- that match nobody join the established pool as they go.
      (shadows2, _) = foldl assignShadow (shadows1, established0) freshTids
      -- Id-switch adoption for fresh ids that weren't shadowed:
      -- inherit the nearest recently-dead track's rule state
      -- (cooldown clock included), matched on its
      -- velocity-extrapolated position.
      (rules1, seen2) = foldl adopt (rules0, seen1) [n | n <- freshTids, not (M.member n shadows2)]
      -- Refresh the memory with this frame's observations (velocity
      -- from the previous entry, capped).
      seen3 =
        foldl refreshSeen seen2 (M.toList liveCenters)
      -- Grace pruning: state survives while its track is live OR
      -- remembered — an absent track is forgotten only after the
      -- memory window elapses.
      rules2 = M.filterWithKey (\(_, tid) _ -> M.member tid seen3) rules1
      step (st', evs) track
        | M.member (let TrackId n = tId track in n) shadows2 = (st', evs)
        | otherwise =
            let p0 = norm (boxCenter (tPrevBox track))
                p1 = norm (boxCenter (tBox track))
                stepRule (st'', evs') rule =
                  let key = (ruleId rule, let TrackId n = tId track in n)
                      prevSt = M.findWithDefault emptyRuleState key st''
                      (mEv, newSt) = evalRule rule (tClassId track) now p0 p1 prevSt
                   in ( M.insert key newSt st'',
                        maybe evs' (\ev -> (rule, track, ev) : evs') mEv
                      )
             in foldl stepRule (st', evs) rules
      (rules3, evs) = foldl step (rules2, []) tracks
   in (EngineState rules3 seen3 shadows2, reverse evs)
  where
    liveTids = [n | Track {tId = TrackId n} <- tracks]
    liveCenters =
      M.fromList
        [ (n, (tClassId tr, norm (boxCenter (tBox tr))))
        | tr@Track {tId = TrackId n} <- tracks
        ]
    norm (V2 (x, y)) =
      V2 (realToFrac x / fromIntegral fw, realToFrac y / fromIntegral fh)
    liveCenterOf n = snd <$> M.lookup n liveCenters
    liveClassOf n = fst <$> M.lookup n liveCenters
    -- \| Resolve one existing shadow mapping.
    inheritStep (ruleMap, seenMap, keep) shadow primary
      -- Shadow gone: drop the mapping, leave everything else.
      | shadow `notElem` liveTids = (ruleMap, seenMap, keep)
      -- Both alive: mapping survives (distance re-validated after).
      | primary `elem` liveTids = (ruleMap, seenMap, M.insert shadow primary keep)
      -- Primary gone, shadow alive: the shadow continues the object's
      -- identity — inherit the primary's rule state, consume the
      -- primary's memory entry.
      | otherwise =
          ( M.mapKeys (\(r, t) -> if t == primary then (r, shadow) else (r, t)) ruleMap,
            M.delete primary seenMap,
            keep
          )
    -- \| A kept mapping holds only while the pair stays close.
    closeLive shadow primary = fromMaybe False $ do
      c1 <- liveCenterOf shadow
      c2 <- liveCenterOf primary
      pure (dist c1 c2 <= shadowMaxDist)
    -- \| Try to enroll a fresh id as a shadow of the nearest
    -- established live track of the same class.
    assignShadow (shs, established) tid =
      case (M.lookup tid liveCenters, bestPrimary shs established tid) of
        (Just _, Just primary) -> (M.insert tid primary shs, established)
        _ -> (shs, tid : established)
    bestPrimary shs established tid = do
      (cls, c) <- M.lookup tid liveCenters
      let cands =
            [ (d, p)
            | p <- established,
              p /= tid,
              not (M.member p shs),
              Just cls == liveClassOf p,
              Just c' <- [liveCenterOf p],
              let d = dist c c',
              d <= shadowMaxDist
            ]
      case sortOn fst cands of
        [] -> Nothing
        ((_, p) : _) -> Just p
    -- \| Adopt the nearest eligible dead track's rule states for a
    -- fresh id. The donor is removed from the memory so it can't be
    -- adopted twice.
    adopt (ruleMap, seenMap) tid =
      case bestDonor seenMap tid of
        Nothing -> (ruleMap, seenMap)
        Just donor ->
          ( M.mapKeys (\(r, t) -> if t == donor then (r, tid) else (r, t)) ruleMap,
            M.delete donor seenMap
          )
    bestDonor seenMap tid = do
      (cls, c) <- M.lookup tid liveCenters
      let cands =
            [ (d, donorTid)
            | (donorTid, s) <- M.toList seenMap,
              donorTid `notElem` liveTids,
              stClassId s == cls,
              let gap = diffUTCTime now (stLastSeen s),
              gap <= handoverWindowSec,
              let predicted = vadd (stCenter s) (vscale (realToFrac gap) (stVelocity s)),
              let d = dist c predicted,
              d <= handoverRadius
            ]
      case sortOn fst cands of
        [] -> Nothing
        ((_, donorTid) : _) -> Just donorTid
    refreshSeen sm (n, (cls, c)) =
      let v = case M.lookup n sm of
            Just old
              | dt > 0 -> capVelocity (vscale (1 / realToFrac dt) (vsub c (stCenter old)))
              | otherwise -> stVelocity old
              where
                dt = diffUTCTime now (stLastSeen old)
            Nothing -> V2 (0, 0)
       in M.insert n (SeenTrack cls c v now) sm

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

vadd :: (Num a) => V2 a -> V2 a -> V2 a
vadd (V2 (x1, y1)) (V2 (x2, y2)) = V2 (x1 + x2, y1 + y2)

vsub :: (Num a) => V2 a -> V2 a -> V2 a
vsub (V2 (x1, y1)) (V2 (x2, y2)) = V2 (x1 - x2, y1 - y2)

vscale :: (Num a) => a -> V2 a -> V2 a
vscale s (V2 (x, y)) = V2 (s * x, s * y)

-- | Clamp a velocity vector to 'maxTrackVelocity' magnitude.
capVelocity :: V2 Double -> V2 Double
capVelocity v@(V2 (x, y)) =
  let l = sqrt (x * x + y * y)
   in if l <= maxTrackVelocity || l == 0 then v else vscale (maxTrackVelocity / l) v

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
