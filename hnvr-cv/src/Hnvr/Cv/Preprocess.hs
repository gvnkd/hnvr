{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | YOLO input preparation: letterbox to 320×320 + normalize.
--
-- Matches Ultralytics preprocessing (design_docs/04-cv-pipeline.md
-- §"Preprocess with massiv"): scale preserving aspect ratio, pad the
-- short side symmetrically with 114/255, NHWC→NCHW, x/255. Same code
-- path whether the frame came from a native sub-stream or the
-- main-stream-with-scale fallback — the analyzer doesn't care.
--
-- The design doc writes the output as @Ix3 1 3 320 320@; massiv's
-- @Ix3@ is exactly three dimensions, so we use @Ix4 1 3 320 320@
-- (batch 1, NCHW). 'toTensor' flattens to the FFI 'Tensor'.
module Hnvr.Cv.Preprocess
  ( Letterbox (..),
    letterboxGeometry,
    preprocessTo,
    preprocess,
    padValue,
    toTensor,
  )
where

import Data.Massiv.Array (Array, Comp (Seq), D, Ix2 ((:.)), Ix4, IxN ((:>)), S (S), Sz4, computeAs, makeArray, size, pattern Sz4)
import Data.Massiv.Array.Manifest.Vector (toVector)
import qualified Data.Vector.Storable as VS
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Cv.OnnxRuntime (Tensor (..))

-- | Letterbox geometry for one frame: scaled dims, symmetric padding,
-- and the uniform scale factor.
data Letterbox = Letterbox
  { lbScaledW :: !Int,
    lbScaledH :: !Int,
    lbPadX :: !Int,
    lbPadY :: !Int,
    lbScale :: !Double
  }
  deriving stock (Eq, Show)

-- | Ultralytics padding value (114) in normalized form.
padValue :: Float
padValue = 114 / 255

-- | Compute the letterbox mapping from @srcW×srcH@ into
-- @targetW×targetH@. Pure; the property tests hang off this.
letterboxGeometry :: Int -> Int -> Int -> Int -> Letterbox
letterboxGeometry targetW targetH srcW srcH =
  let scale =
        min
          (fromIntegral targetW / fromIntegral srcW)
          (fromIntegral targetH / fromIntegral srcH)
      scaledW = max 1 (round (fromIntegral srcW * scale))
      scaledH = max 1 (round (fromIntegral srcH * scale))
   in Letterbox
        { lbScaledW = scaledW,
          lbScaledH = scaledH,
          lbPadX = (targetW - scaledW) `div` 2,
          lbPadY = (targetH - scaledH) `div` 2,
          lbScale = scale
        }

-- | Letterbox + normalize a frame into @Array S Ix4 Float@ of shape
-- @1×3×target×target@ (NCHW, batch 1). Bilinear sampling on the
-- scaled region; 'padValue' outside it.
preprocessTo :: Int -> Frame -> Array S Ix4 Float
preprocessTo target Frame {frameWidth = srcW, frameHeight = srcH, frameRgb = rgb} =
  computeAs S delayed
  where
    lb = letterboxGeometry target target srcW srcH

    delayed :: Array D Ix4 Float
    delayed =
      makeArray Seq (Sz4 1 3 target target) $ \(0 :> c :> y :. x) ->
        if x < lbPadX lb
          || x >= lbPadX lb + lbScaledW lb
          || y < lbPadY lb
          || y >= lbPadY lb + lbScaledH lb
          then padValue
          else sample c x y / 255

    -- Bilinear sample of channel @c@ at output pixel @(x,y)@, mapped
    -- back into source coordinates. Edge-clamped.
    sample :: Int -> Int -> Int -> Float
    sample c x y =
      let sx = (fromIntegral (x - lbPadX lb) + 0.5) / lbScale lb - 0.5 :: Double
          sy = (fromIntegral (y - lbPadY lb) + 0.5) / lbScale lb - 0.5
          x0 = clampX (floor sx)
          y0 = clampY (floor sy)
          x1 = clampX (x0 + 1)
          y1 = clampY (y0 + 1)
          fx = sx - fromIntegral (floor sx :: Int)
          fy = sy - fromIntegral (floor sy :: Int)
          px :: Int -> Int -> Double
          px ix iy = fromIntegral (rgb VS.! ((iy * srcW + ix) * 3 + c))
          top = px x0 y0 * (1 - fx) + px x1 y0 * fx
          bot = px x0 y1 * (1 - fx) + px x1 y1 * fx
       in realToFrac (top * (1 - fy) + bot * fy)

    clampX, clampY :: Int -> Int
    clampX = max 0 . min (srcW - 1)
    clampY = max 0 . min (srcH - 1)

-- | 'preprocessTo' at the YOLOv8n-320 input size.
preprocess :: Frame -> Array S Ix4 Float
preprocess = preprocessTo 320

-- | Convert a preprocessed array into the FFI 'Tensor' shape
-- (@tensorShape [1,3,target,target]@, row-major storable vector).
toTensor :: Array S Ix4 Float -> Tensor
toTensor arr =
  let Sz4 _ _ h w = size arr
   in Tensor {tensorShape = [1, 3, fromIntegral h, fromIntegral w], tensorData = toVector arr}
