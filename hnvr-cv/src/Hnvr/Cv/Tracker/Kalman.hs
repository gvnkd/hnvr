{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Constant-velocity Kalman filter for SORT, 6-dim state / 4-dim
-- measurement per design_docs/04-cv-pipeline.md:
--
--   state:        [cx, cy, s, r, vcx, vcy]
--   measurement:  [cx, cy, s, r]
--
-- where @s = w*h@ (scale) and @r = w/h@ (aspect ratio), following the
-- SORT paper. The design calls this @Kalman6x4@ and suggests massiv's
-- Matrix; massiv has no 4×4 inverse, so this module carries its own
-- tiny dense-matrix ops over boxed vectors (~70 LOC, deterministic
-- Gauss-Jordan with partial pivot).
module Hnvr.Cv.Tracker.Kalman
  ( Kalman,
    initKalman,
    predict,
    update,
    kalmanBox,
    measOfBox,
  )
where

import qualified Data.Vector as V
import Hnvr.Core.Geometry (Box (..))

-- | Opaque filter state: state vector (6) + covariance (6×6).
data Kalman = Kalman
  { kX :: !(V.Vector Double),
    kP :: !Matrix
  }
  deriving stock (Eq, Show)

type Matrix = V.Vector (V.Vector Double)

-- | Initialize at a measurement. Velocity starts at zero with large
-- covariance (SORT: velocity variance ≫ position variance).
initKalman :: Box Float -> Kalman
initKalman box =
  Kalman
    { kX = measOfBox box <> V.fromList [0, 0],
      kP = diag [1, 1, 1, 1, 100, 100]
    }

-- | Time-update step (dt = 1 frame).
predict :: Kalman -> Kalman
predict Kalman {kX = x, kP = p} =
  Kalman
    { kX = matVec transition x,
      kP = matMul transition (matMul p (transpose transition)) `add` processNoise
    }

-- | Measurement-update step.
update :: Box Float -> Kalman -> Kalman
update box Kalman {kX = x, kP = p} =
  let z = measOfBox box
      y = V.zipWith (-) z (matVec measure x)
      s = matMul measure (matMul p (transpose measure)) `add` measNoise
      kGain = matMul (matMul p (transpose measure)) (inverse s)
      x' = V.zipWith (+) x (matVec kGain y)
      p' = matMul (identity 6 `sub` matMul kGain measure) p
   in Kalman {kX = x', kP = p'}

-- | Current state as a box. Guards against degenerate scale/aspect
-- from early covariance swings.
kalmanBox :: Kalman -> Box Float
kalmanBox Kalman {kX = x} =
  let cx = x V.! 0
      cy = x V.! 1
      s = max 1 (x V.! 2)
      r = max 0.01 (x V.! 3)
      w = sqrt (s * r)
      h = s / w
   in Box
        { bxX = realToFrac (cx - w / 2),
          bxY = realToFrac (cy - h / 2),
          bxW = realToFrac w,
          bxH = realToFrac h
        }

-- | Box → measurement vector [cx, cy, s, r].
measOfBox :: Box Float -> V.Vector Double
measOfBox Box {bxX = x, bxY = y, bxW = w, bxH = h} =
  let w' = max 1e-3 (realToFrac w)
      h' = max 1e-3 (realToFrac h)
   in V.fromList
        [ realToFrac x + w' / 2,
          realToFrac y + h' / 2,
          w' * h',
          w' / h'
        ]

-- Constant-velocity transition: position += velocity.
transition :: Matrix
transition =
  V.fromList
    [ V.fromList [1, 0, 0, 0, 1, 0],
      V.fromList [0, 1, 0, 0, 0, 1],
      V.fromList [0, 0, 1, 0, 0, 0],
      V.fromList [0, 0, 0, 1, 0, 0],
      V.fromList [0, 0, 0, 0, 1, 0],
      V.fromList [0, 0, 0, 0, 0, 1]
    ]

-- Measurement picks the first four state components.
measure :: Matrix
measure =
  V.fromList
    [ V.fromList [1, 0, 0, 0, 0, 0],
      V.fromList [0, 1, 0, 0, 0, 0],
      V.fromList [0, 0, 1, 0, 0, 0],
      V.fromList [0, 0, 0, 1, 0, 0]
    ]

-- Process noise (SORT uses ~0.01 on positions, ~0.01 on velocities
-- for the 6-dim variant).
processNoise :: Matrix
processNoise = diag [0.01, 0.01, 0.01, 0.01, 0.01, 0.01]

-- Measurement noise; scale/aspect are noisier than center.
measNoise :: Matrix
measNoise = diag [1, 1, 10, 10]

-- Tiny dense-matrix ops ------------------------------------------------

diag :: [Double] -> Matrix
diag xs = V.generate n $ \i -> V.generate n $ \j -> if i == j then xs !! i else 0
  where
    n = length xs

identity :: Int -> Matrix
identity n = diag (replicate n 1)

add, sub :: Matrix -> Matrix -> Matrix
add = V.zipWith (V.zipWith (+))
sub = V.zipWith (V.zipWith (-))

transpose :: Matrix -> Matrix
transpose m = V.generate (V.length (V.head m)) $ \j -> V.generate (V.length m) $ \i -> (m V.! i) V.! j

matVec :: Matrix -> V.Vector Double -> V.Vector Double
matVec m v = V.map (\row -> V.sum (V.zipWith (*) row v)) m

matMul :: Matrix -> Matrix -> Matrix
matMul a b =
  let bt = transpose b
   in V.map (\row -> V.map (V.sum . V.zipWith (*) row) bt) a

-- | Gauss-Jordan inverse with partial pivoting. Only used on the 4×4
-- innovation covariance (symmetric positive-definite by construction),
-- but written generically. Errors on a singular matrix — a
-- programmer/Kalman-tuning error, not runtime data.
inverse :: Matrix -> Matrix
inverse m =
  let n = V.length m
      aug = V.generate n $ \i -> m V.! i V.++ identity n V.! i
      reduced = foldl elim aug [0 .. n - 1]
   in V.map (V.drop n) reduced
  where
    elim a col =
      let pivotRow = V.maxIndex (V.map (\row -> abs (row V.! col)) (V.drop col a)) + col
          swapped = swapRows a col pivotRow
          pivot = (swapped V.! col) V.! col
       in if abs pivot < 1e-12
            then error "Hnvr.Cv.Tracker.Kalman.inverse: singular matrix"
            else
              let normed = V.update swapped (V.singleton (col, V.map (/ pivot) (swapped V.! col)))
               in V.generate (V.length normed) $ \i ->
                    if i == col
                      then normed V.! i
                      else
                        let f = (normed V.! i) V.! col
                         in V.zipWith (-) (normed V.! i) (V.map (* f) (normed V.! col))

    swapRows :: Matrix -> Int -> Int -> Matrix
    swapRows a i j
      | i == j = a
      | otherwise = V.generate (V.length a) $ \r -> if r == i then a V.! j else if r == j then a V.! i else a V.! r
