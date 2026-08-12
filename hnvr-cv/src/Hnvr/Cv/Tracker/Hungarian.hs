-- | Hungarian (Kuhn–Munkres) minimum-cost bipartite assignment.
--
-- The design doc names a @hungarian-algorithm-1.0.0@ Hackage package
-- — no such package exists (checked Aug 12 2026), so this is a
-- self-contained port of the classic O(n³) potential-based algorithm
-- (e-maxx formulation) over 'Data.Vector' + 'ST'. Deterministic:
-- strict-@<@ comparisons break ties toward lower column indices, so
-- the same cost matrix always yields the same assignment.
--
-- Handles rectangular matrices by square-padding with a
-- caller-supplied dummy cost (use a cost ≥ any real cost; matches
-- against dummy cells mean "unassigned" to the caller).
module Hnvr.Cv.Tracker.Hungarian
  ( hungarian,
  )
where

import Control.Monad (forM_, unless, when)
import Control.Monad.ST (ST, runST)
import qualified Data.Vector as V
import qualified Data.Vector.Mutable as MV

-- | @hungarian dummyCost cost@ returns, for each row, the matched
-- column index (0-based into the padded square matrix). Rows or
-- columns beyond the input's real dimensions are dummy cells filled
-- with @dummyCost@ (dummy–dummy pairs cost 0). Requires a non-empty
-- cost matrix; the empty case returns an empty assignment.
hungarian :: Double -> V.Vector (V.Vector Double) -> V.Vector Int
hungarian dummyCost cost
  | nRows == 0 || nCols == 0 = V.empty
  | otherwise =
      let k = max nRows nCols
          padded =
            V.generate k $ \i ->
              V.generate k $ \j ->
                if i < nRows && j < nCols
                  then (cost V.! i) V.! j
                  else if i >= nRows && j >= nCols then 0 else dummyCost
          assignment = runST (hungarianST k padded)
       in V.take nRows assignment
  where
    nRows = V.length cost
    nCols = if nRows == 0 then 0 else V.length (V.head cost)

-- 1-indexed e-maxx Hungarian. Returns 0-based row→column assignment.
hungarianST :: Int -> V.Vector (V.Vector Double) -> ST s (V.Vector Int)
hungarianST k a = do
  u <- MV.replicate (k + 1) 0
  v <- MV.replicate (k + 1) 0
  p <- MV.replicate (k + 1) 0 -- p[j] = row matched to column j
  way <- MV.replicate (k + 1) 0
  forM_ [1 .. k] $ \i -> do
    MV.write p 0 i
    minv <- MV.replicate (k + 1) (1 / 0 :: Double)
    used <- MV.replicate (k + 1) False
    let loop j0 = do
          MV.write used j0 True
          i0 <- MV.read p j0
          (delta, j1) <- foldScan u v way i0 minv used j0 (1 / 0) 0
          forM_ [0 .. k] $ \j -> do
            isUsed <- MV.read used j
            if isUsed
              then do
                pj <- MV.read p j
                MV.modify u (+ delta) pj
                MV.modify v (subtract delta) j
              else MV.modify minv (subtract delta) j
          pj1 <- MV.read p j1
          if pj1 /= 0 then loop j1 else augment p way j1
    loop 0
  assignment <- MV.new k
  forM_ [1 .. k] $ \j -> do
    pj <- MV.read p j
    when (pj /= 0) $ MV.write assignment (pj - 1) (j - 1)
  V.freeze assignment
  where
    -- Scan unused columns for the current row, updating minv/way and
    -- returning (delta, nextColumn).
    foldScan u v way i0 minv used j0 = go 1
      where
        go j delta j1
          | j > k = pure (delta, j1)
          | otherwise = do
              isUsed <- MV.read used j
              if isUsed
                then go (j + 1) delta j1
                else do
                  ui0 <- MV.read u i0
                  vj <- MV.read v j
                  let cur = ((a V.! (i0 - 1)) V.! (j - 1)) - ui0 - vj
                  curMin <- MV.read minv j
                  newMin <-
                    if cur < curMin
                      then do
                        MV.write minv j cur
                        MV.write way j j0
                        pure cur
                      else pure curMin
                  if newMin < delta
                    then go (j + 1) newMin j
                    else go (j + 1) delta j1

    augment p way j0 = do
      w <- MV.read way j0
      pw <- MV.read p w
      MV.write p j0 pw
      unless (w == 0) (augment p way w)
