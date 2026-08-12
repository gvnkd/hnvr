{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | YOLOv8 anchor decode + per-class NMS.
--
-- Input is the raw pre-NMS model output @[1, 84, 2100]@ float32:
-- 4 box channels (cx, cy, w, h — letterbox pixels, no objectness in
-- v8) + 80 COCO class scores. We filter by confidence + class
-- whitelist, then run vanilla per-class NMS
-- (design_docs/04-cv-pipeline.md §3). Boxes stay in the 320×320
-- letterbox space; 'unletterboxBox' maps them back to source-frame
-- pixels using the 'Letterbox' from preprocessing.
module Hnvr.Cv.Decode
  ( Detection (..),
    decode,
    nms,
    iou,
    unletterboxBox,
    unletterboxDetection,
    defaultKeepClasses,
    defaultConfThreshold,
    defaultNmsIou,
    defaultMaxPerClass,
  )
where

import Data.List (groupBy, sortBy)
import Data.Ord (Down (..), comparing)
import qualified Data.Vector as V
import qualified Data.Vector.Storable as VS
import Hnvr.Core.Geometry (Box (..))
import Hnvr.Cv.OnnxRuntime (Tensor (..))
import Hnvr.Cv.Preprocess (Letterbox (..))

-- | One decoded detection in letterbox pixel coordinates.
data Detection = Detection
  { detBox :: !(Box Float),
    detClassId :: !Int,
    detScore :: !Float
  }
  deriving stock (Eq, Show)

-- | COCO classes we care about by default: person, bicycle, car,
-- motorcycle, bus, truck (design §"Model: YOLOv8n"). Overridable per
-- camera via @cameras.kept_classes@ (Phase 4 wiring).
defaultKeepClasses :: Int -> Bool
defaultKeepClasses c = c `elem` [0, 1, 2, 3, 5, 7]

-- | Per-camera confidence threshold default (design §3).
defaultConfThreshold :: Float
defaultConfThreshold = 0.35

-- | NMS IoU threshold default (design §"NMS in Haskell").
defaultNmsIou :: Float
defaultNmsIou = 0.45

-- | Max kept detections per class (design §"NMS in Haskell").
defaultMaxPerClass :: Int
defaultMaxPerClass = 100

-- | Decode a @[1, 84, anchors]@ float32 tensor into detections at or
-- above the confidence threshold whose class passes the filter.
-- Precondition failure (wrong shape) is a programmer error.
decode :: Float -> (Int -> Bool) -> Tensor -> V.Vector Detection
decode confThreshold keepClass Tensor {tensorShape = shape, tensorData = dat} =
  case shape of
    [1, 84, anchors] -> V.mapMaybe decodeOne (V.generate n id)
      where
        n = fromIntegral anchors :: Int
        at :: Int -> Int -> Float
        at channel i = dat VS.! (channel * n + i)
        decodeOne :: Int -> Maybe Detection
        decodeOne i =
          let cx = at 0 i
              cy = at 1 i
              w = at 2 i
              h = at 3 i
              score k = at (4 + k) i
              best = V.maxIndex (V.generate 80 score)
           in if score best >= confThreshold && keepClass best
                then Just (Detection (Box (cx - w / 2) (cy - h / 2) w h) best (score best))
                else Nothing
    _ ->
      error
        ( "Hnvr.Cv.Decode.decode: expected tensor shape [1, 84, anchors], got "
            <> show shape
        )

-- | Intersection-over-union of two boxes.
iou :: Box Float -> Box Float -> Float
iou a b =
  let x1 = max (bxX a) (bxX b)
      y1 = max (bxY a) (bxY b)
      x2 = min (bxX a + bxW a) (bxX b + bxW b)
      y2 = min (bxY a + bxH a) (bxY b + bxH b)
      inter = max 0 (x2 - x1) * max 0 (y2 - y1)
      union = bxW a * bxH a + bxW b * bxH b - inter
   in if union <= 0 then 0 else inter / union

-- | Per-class NMS: within each class, sort by descending score and
-- greedily drop boxes with IoU ≥ threshold against an already-kept
-- box; keep at most @maxPerClass@ per class. Total deterministic
-- order (score, class, box coords) so @nms . nms == nms@ holds.
nms :: Float -> Int -> V.Vector Detection -> V.Vector Detection
nms iouThreshold maxPerClass =
  V.fromList
    . concatMap nmsClass
    . groupBy sameClass
    . sortBy (comparing detClassId)
    . V.toList
  where
    sameClass a b = detClassId a == detClassId b

    -- Kept list stays in descending-score order; suppression is
    -- stable, so a second nms pass is the identity.
    nmsClass :: [Detection] -> [Detection]
    nmsClass clsDets =
      take maxPerClass $
        foldl keep [] (sortBy (comparing (Down . detScore)) clsDets)
      where
        keep kept d
          | any (\k -> iou (detBox k) (detBox d) >= iouThreshold) kept = kept
          | otherwise = kept ++ [d]

-- | Map a letterbox-space box back into source-frame pixels.
unletterboxBox :: Letterbox -> Box Float -> Box Float
unletterboxBox lb Box {bxX = x, bxY = y, bxW = w, bxH = h} =
  let s = realToFrac (lbScale lb)
      un coord pad = (coord - fromIntegral pad) / s
   in Box
        { bxX = un x (lbPadX lb),
          bxY = un y (lbPadY lb),
          bxW = w / s,
          bxH = h / s
        }

-- | 'unletterboxBox' lifted over a detection.
unletterboxDetection :: Letterbox -> Detection -> Detection
unletterboxDetection lb d = d {detBox = unletterboxBox lb (detBox d)}
