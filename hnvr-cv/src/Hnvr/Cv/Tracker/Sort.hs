{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | SORT tracker (Bewley, ICIP 2016) in pure Haskell.
--
-- Per frame: Kalman-predict all tracks → Hungarian-assign detections
-- to predicted boxes on @1 - IoU@ cost → update matched, age
-- unmatched, birth new (design_docs/04-cv-pipeline.md §"Tracker:
-- SORT in Haskell"). Tracks below the IoU gate and past 'trMaxAge'
-- misses are dropped; 'confirmedTracks' exposes the ones eligible
-- for rule evaluation (@trMinHits@ consecutive-ish hits).
--
-- Determinism: tracks iterate in ascending-key 'IntMap' order and
-- 'hungarian' breaks ties toward lower indices, so identical
-- detection sequences always produce identical trackers.
module Hnvr.Cv.Tracker.Sort
  ( TrackId (..),
    Track (..),
    Tracker (..),
    newTracker,
    defaultMaxAge,
    defaultMinHits,
    defaultIouGate,
    update,
    confirmedTracks,
    isConfirmed,
  )
where

import Data.IntMap (IntMap)
import qualified Data.IntMap as IM
import qualified Data.Vector as V
import Hnvr.Core.Geometry (Box)
import Hnvr.Cv.Decode (Detection (..), iou)
import Hnvr.Cv.Tracker.Hungarian (hungarian)
import Hnvr.Cv.Tracker.Kalman (Kalman, initKalman, kalmanBox, predict)
import qualified Hnvr.Cv.Tracker.Kalman as K

-- | Stable track identity, monotonically increasing per 'Tracker'.
newtype TrackId = TrackId Int
  deriving stock (Eq, Ord, Show)

data Track = Track
  { tId :: !TrackId,
    -- | Current best box estimate (Kalman-smoothed).
    tBox :: !(Box Float),
    tClassId :: !Int,
    -- | Score of the last matched detection.
    tScore :: !Float,
    tHits :: !Int,
    tTimeSinceUpdate :: !Int,
    tAge :: !Int,
    tKalman :: !Kalman
  }
  deriving stock (Eq, Show)

data Tracker = Tracker
  { trNextId :: !Int,
    trMaxAge :: !Int,
    trMinHits :: !Int,
    trIouGate :: !Float,
    trTracks :: !(IntMap Track)
  }
  deriving stock (Eq, Show)

-- | Frames a track may go unmatched before deletion (design: 30).
defaultMaxAge :: Int
defaultMaxAge = 30

-- | Hits before a track is confirmed / eligible for events
-- (design: 3).
defaultMinHits :: Int
defaultMinHits = 3

-- | Minimum IoU for a detection↔track match (design: 0.3).
defaultIouGate :: Float
defaultIouGate = 0.3

newTracker :: Tracker
newTracker =
  Tracker
    { trNextId = 1,
      trMaxAge = defaultMaxAge,
      trMinHits = defaultMinHits,
      trIouGate = defaultIouGate,
      trTracks = IM.empty
    }

-- | One tracker step. Consumes this frame's detections; returns the
-- updated tracker (matched, aged, birthed, pruned).
update :: Tracker -> V.Vector Detection -> Tracker
update tr dets =
  let predicted = IM.map predictTrack (trTracks tr)
      keys = IM.keys predicted
      detList = V.toList dets
      cost =
        V.fromList
          [ V.fromList [1 - realToFrac (iou (tBox t) (detBox d)) | d <- detList]
          | k <- keys,
            let t = predicted IM.! k
          ]
      assignment = hungarian 1.0 cost
      matches
        | null keys || null detList = []
        | otherwise =
            [ (k, j)
            | (i, k) <- zip [0 ..] keys,
              let j = assignment V.! i,
              j < length detList,
              let d = detList !! j,
              iou (tBox (predicted IM.! k)) (detBox d) >= trIouGate tr
            ]
      matchedKeys = IM.fromList [(k, j) | (k, j) <- matches]
      matchedDets = IM.fromList [(j, ()) | (_, j) <- matches]
      afterMatch = IM.mapWithKey (applyMatch matchedKeys detList) predicted
      births =
        [ initTrack (TrackId nid) d
        | (j, d) <- zip [0 ..] detList,
          IM.notMember j matchedDets,
          let nid = trNextId tr + countEarlier j
        ]
      countEarlier j =
        length [() | (j', _) <- zip [0 ..] detList, j' < j, IM.notMember j' matchedDets]
      afterBirths = foldl (\m t -> IM.insert (unTrackId (tId t)) t m) afterMatch births
      afterPrune = IM.filter (\t -> tTimeSinceUpdate t <= trMaxAge tr) afterBirths
   in tr
        { trNextId = trNextId tr + length births,
          trTracks = afterPrune
        }
  where
    predictTrack t =
      let k' = predict (tKalman t)
       in t {tKalman = k', tBox = kalmanBox k', tAge = tAge t + 1, tTimeSinceUpdate = tTimeSinceUpdate t + 1}

    applyMatch matched detList k t =
      case IM.lookup k matched of
        Nothing -> t
        Just j ->
          let d = detList !! j
              k' = K.update (detBox d) (tKalman t)
           in t
                { tKalman = k',
                  tBox = kalmanBox k',
                  tClassId = detClassId d,
                  tScore = detScore d,
                  tHits = tHits t + 1,
                  tTimeSinceUpdate = 0
                }

    initTrack tid d =
      Track
        { tId = tid,
          tBox = detBox d,
          tClassId = detClassId d,
          tScore = detScore d,
          tHits = 1,
          tTimeSinceUpdate = 0,
          tAge = 1,
          tKalman = initKalman (detBox d)
        }

    unTrackId (TrackId n) = n

-- | Tracks past the confirmation threshold — the set rules/auto-track
-- should evaluate.
confirmedTracks :: Tracker -> [Track]
confirmedTracks tr = filter (isConfirmed tr) (IM.elems (trTracks tr))

isConfirmed :: Tracker -> Track -> Bool
isConfirmed tr t = tHits t >= trMinHits tr
