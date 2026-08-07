{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DeriveTraversable #-}

-- | Geometry primitives for CV.
--
-- All boxes used by the rules engine are stored in /normalized/ image
-- coordinates (0..1 in both axes) so they are resolution-independent — the
-- same bbox can be drawn on top of a 640×480 sub-stream frame or a 4K
-- recording and it lines up either way.
module Hnvr.Core.Geometry
  ( Box(..)
  , NBox
  , V2(..)
  ) where

import GHC.Generics (Generic)

-- | Axis-aligned bounding box parameterized over the coordinate type.
--
-- Stored as top-left corner + width\/height rather than center+wh because
-- that's what YOLOv8 NMS expects and what ONVIF PTZ controllers expect.
data Box a = Box
  { bxX :: !a
  , bxY :: !a
  , bxW :: !a
  , bxH :: !a
  } deriving stock
    ( Eq, Ord, Show, Generic
    , Functor, Foldable, Traversable
    )

-- | Box in normalized image coordinates (0..1).
type NBox = Box Double

-- | 2D vector. Used for line endpoints, motion deltas, polygon vertices.
newtype V2 a = V2 { unV2 :: (a, a) }
  deriving stock
    ( Eq, Ord, Show, Generic
    , Functor
    )
