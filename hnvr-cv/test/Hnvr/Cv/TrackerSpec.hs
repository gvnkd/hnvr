{-# LANGUAGE ScopedTypeVariables #-}

-- | Tests for the SORT tracker stack: "Hnvr.Cv.Tracker.Hungarian"
-- (golden assignments, rectangular padding, determinism),
-- "Hnvr.Cv.Tracker.Kalman" (round-trip, update convergence, velocity
-- learning), and "Hnvr.Cv.Tracker.Sort" (birth/match/age/prune,
-- confirmation, IoU gating) plus the determinism + ID-stability
-- properties from design_docs/09-testing.md.
module Hnvr.Cv.TrackerSpec (tests) where

import qualified Data.IntMap as IM
import qualified Data.Vector as V
import Hnvr.Core.Geometry (Box (..))
import Hnvr.Cv.Decode (Detection (..))
import Hnvr.Cv.Tracker.Hungarian (hungarian)
import Hnvr.Cv.Tracker.Kalman (initKalman, kalmanBox, predict, update)
import Hnvr.Cv.Tracker.Sort
  ( Track (..),
    TrackId (..),
    Tracker (..),
    confirmedTracks,
    newTracker,
  )
import qualified Hnvr.Cv.Tracker.Sort as Sort
import Test.QuickCheck (Property, choose, forAll, listOf, resize, (===))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Test.Tasty.QuickCheck (testProperty)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Cv.Tracker"
    [ testGroup
        "Hungarian"
        [ testCase "2x2 diagonal optimum" $
            hungarian 1.0 (mat [[0.1, 0.9], [0.9, 0.2]]) @?= V.fromList [0, 1],
          testCase "2x2 off-diagonal optimum" $
            hungarian 1.0 (mat [[0.9, 0.1], [0.1, 0.9]]) @?= V.fromList [1, 0],
          testCase "rectangular 2x3 picks best columns" $
            hungarian 1.0 (mat [[0.5, 0.1, 0.9], [0.9, 0.8, 0.1]]) @?= V.fromList [1, 2],
          testCase "more rows than columns: surplus row lands on dummy" $ do
            let a = hungarian 1.0 (mat [[0.9, 0.9], [0.1, 0.9], [0.9, 0.1]])
            a V.! 1 @?= 0
            a V.! 2 @?= 1
            assertBool ("row 0 unmatched (dummy col), got " <> show (a V.! 0)) (a V.! 0 >= 2),
          testCase "ties break toward lower column index" $
            hungarian 1.0 (mat [[0.5, 0.5]]) @?= V.fromList [0],
          testCase "empty cost matrix" $
            hungarian 1.0 V.empty @?= V.empty
        ],
      testGroup
        "Kalman"
        [ testCase "initKalman round-trips the input box" $ do
            let box = Box 10 20 30 40
                out = kalmanBox (initKalman box)
            assertBool ("x " <> show out) (abs (bxX out - 10) < 1e-3)
            assertBool ("y " <> show out) (abs (bxY out - 20) < 1e-3)
            assertBool ("w " <> show out) (abs (bxW out - 30) < 1e-2)
            assertBool ("h " <> show out) (abs (bxH out - 40) < 1e-2),
          testCase "update moves the estimate toward the measurement" $ do
            let k0 = initKalman (Box 0 0 10 10)
                k1 = update (Box 20 0 10 10) k0
                cx0 = bxX (kalmanBox k0) + bxW (kalmanBox k0) / 2
                cx1 = bxX (kalmanBox k1) + bxW (kalmanBox k1) / 2
            assertBool ("cx moved " <> show (cx0, cx1)) (cx1 > cx0),
          testCase "constant motion teaches velocity; predict extrapolates" $ do
            let k0 = initKalman (Box 0 0 10 10)
                k1 = update (Box 0 0 10 10) k0
                k2 = update (Box 10 0 10 10) (predict k1)
                k3 = update (Box 20 0 10 10) (predict k2)
                predicted = predict k3
                cx3 = bxX (kalmanBox k3)
                cxP = bxX (kalmanBox predicted)
            assertBool ("predict should lead measurement " <> show (cx3, cxP)) (cxP > cx3)
        ],
      testGroup
        "Sort"
        [ testCase "first detection births tentative track 1" $ do
            let tr = Sort.update newTracker (V.singleton (det (Box 0 0 10 10) 0.9))
            IM.size (trTracks tr) @?= 1
            tId (head (IM.elems (trTracks tr))) @?= TrackId 1
            confirmedTracks tr @?= [],
          testCase "same-ish box next frame keeps the track" $ do
            let tr1 = Sort.update newTracker (V.singleton (det (Box 0 0 10 10) 0.9))
                tr2 = Sort.update tr1 (V.singleton (det (Box 1 0 10 10) 0.8))
            IM.size (trTracks tr2) @?= 1
            tId (head (IM.elems (trTracks tr2))) @?= TrackId 1,
          testCase "far-away box births a second track" $ do
            let tr1 = Sort.update newTracker (V.singleton (det (Box 0 0 10 10) 0.9))
                tr2 = Sort.update tr1 (V.singleton (det (Box 200 200 10 10) 0.8))
            IM.size (trTracks tr2) @?= 2,
          testCase "track pruned after maxAge misses" $ do
            let tr0 = newTracker {trMaxAge = 1}
                tr1 = Sort.update tr0 (V.singleton (det (Box 0 0 10 10) 0.9))
                tr2 = Sort.update tr1 V.empty
                tr3 = Sort.update tr2 V.empty
            IM.size (trTracks tr2) @?= 1
            IM.size (trTracks tr3) @?= 0,
          testCase "confirmed after minHits matches" $ do
            let frames = replicate 3 (V.singleton (det (Box 0 0 10 10) 0.9))
                tr = foldl Sort.update newTracker frames
            length (confirmedTracks tr) @?= 1,
          testCase "below-gate IoU does not match" $ do
            -- 10x10 box moved 8px right: IoU = 2/18 < 0.3
            let tr1 = Sort.update newTracker (V.singleton (det (Box 0 0 10 10) 0.9))
                tr2 = Sort.update tr1 (V.singleton (det (Box 8 0 10 10) 0.8))
            IM.size (trTracks tr2) @?= 2
        ],
      testGroup
        "properties"
        [ testProperty "same detections → same tracker (determinism)" prop_determinism,
          testProperty "constant-velocity target keeps track id 1" prop_idStable
        ]
    ]
  where
    mat = V.fromList . map V.fromList
    det box score = Detection {detBox = box, detClassId = 0, detScore = score}

prop_determinism :: Property
prop_determinism =
  -- Hungarian is O(n³) per frame; keep the generated sequence small
  -- or default-size-100 runs take minutes.
  forAll (resize 12 (listOf (listOf genDetection))) $ \frames ->
    let run = foldl Sort.update newTracker (map V.fromList (frames :: [[Detection]]))
     in run === run
  where
    genDetection =
      Detection
        <$> (Box <$> choose (0, 320) <*> choose (0, 320) <*> choose (1, 100) <*> choose (1, 100))
        <*> choose (0, 79)
        <*> choose (0, 1)

-- A box gliding 5px/frame (IoU 0.6 between consecutive frames) must
-- keep its track identity for the whole sequence.
prop_idStable :: Property
prop_idStable =
  forAll (choose (2, 15)) $ \n ->
    let frames =
          [ V.singleton (Detection {detBox = Box (fromIntegral i * 5) 100 20 20, detClassId = 0, detScore = 0.9})
          | i <- [0 .. n - 1]
          ]
        tr = foldl Sort.update newTracker frames
        tracks = IM.elems (trTracks tr)
     in length tracks == 1
          && tId (head tracks) == TrackId 1
