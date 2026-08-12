{-# LANGUAGE ScopedTypeVariables #-}

-- | Tests for "Hnvr.Cv.Decode".
--
-- Golden decode on a hand-built @[1, 84, 3]@ tensor, NMS behavior
-- (suppression, class isolation, cap, ordering), IoU arithmetic,
-- unletterbox mapping, and the two anchor properties from
-- design_docs/09-testing.md: @nms . nms == nms@ and decode respecting
-- its filters.
module Hnvr.Cv.DecodeSpec (tests) where

import qualified Data.Vector as V
import qualified Data.Vector.Storable as VS
import Hnvr.Core.Geometry (Box (..))
import Hnvr.Cv.Decode
  ( Detection (..),
    decode,
    defaultConfThreshold,
    defaultKeepClasses,
    defaultMaxPerClass,
    defaultNmsIou,
    iou,
    nms,
    unletterboxBox,
  )
import Hnvr.Cv.OnnxRuntime (Tensor (..))
import Hnvr.Cv.Preprocess (letterboxGeometry)
import Test.QuickCheck (Arbitrary (arbitrary), Property, choose, forAll, vectorOf, (===))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))
import Test.Tasty.QuickCheck (testProperty)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Cv.Decode"
    [ testGroup
        "decode (golden)"
        [ testCase "decodes anchors above threshold in kept classes" $ do
            let dets = decode defaultConfThreshold defaultKeepClasses goldenTensor
            V.length dets @?= 2
            let d0 = dets V.! 0
                d1 = dets V.! 1
            detBox d0 @?= Box 90 45 20 10
            detClassId d0 @?= 0
            detScore d0 @?= 0.9
            detBox d1 @?= Box 185 85 30 30
            detClassId d1 @?= 5
            detScore d1 @?= 0.5,
          testCase "respects the confidence threshold" $ do
            let dets = decode 0.95 defaultKeepClasses goldenTensor
            V.null dets @?= True,
          testCase "respects the class filter" $ do
            let dets = decode defaultConfThreshold (== 0) goldenTensor
            V.length dets @?= 1
            detClassId (V.head dets) @?= 0
        ],
      testGroup
        "iou"
        [ testCase "identical boxes" $ iou (Box 0 0 10 10) (Box 0 0 10 10) @?= 1,
          testCase "disjoint boxes" $ iou (Box 0 0 10 10) (Box 20 0 10 10) @?= 0,
          testCase "half-overlapping boxes" $ do
            let v = iou (Box 0 0 10 10) (Box 5 0 10 10)
            assertBool ("iou " <> show v) (abs (v - 50 / 150) < 1e-6)
        ],
      testGroup
        "nms"
        [ testCase "suppresses overlapping same-class, keeps higher score" $ do
            let hi = Detection (Box 0 0 10 10) 0 0.9
                lo = Detection (Box 1 1 10 10) 0 0.5
                out = nms defaultNmsIou defaultMaxPerClass (V.fromList [lo, hi])
            V.toList out @?= [hi],
          testCase "different classes never suppress each other" $ do
            let a = Detection (Box 0 0 10 10) 0 0.9
                b = Detection (Box 0 0 10 10) 1 0.8
                out = nms defaultNmsIou defaultMaxPerClass (V.fromList [a, b])
            V.length out @?= 2,
          testCase "non-overlapping same-class kept" $ do
            let a = Detection (Box 0 0 10 10) 0 0.9
                b = Detection (Box 100 100 10 10) 0 0.8
                out = nms defaultNmsIou defaultMaxPerClass (V.fromList [b, a])
            V.length out @?= 2,
          testCase "maxPerClass caps the kept list" $ do
            let dets = V.fromList [Detection (Box (i * 100) 0 10 10) 0 0.9 | i <- [0 .. 4]]
                out = nms defaultNmsIou 2 dets
            V.length out @?= 2,
          testCase "output is sorted by descending score within class" $ do
            let a = Detection (Box 0 0 10 10) 0 0.7
                b = Detection (Box 100 100 10 10) 0 0.9
                c = Detection (Box 200 200 10 10) 0 0.8
                out = nms defaultNmsIou defaultMaxPerClass (V.fromList [a, b, c])
            V.toList out @?= [b, c, a]
        ],
      testCase "unletterboxBox maps 320-space back to source pixels" $ do
        let lb = letterboxGeometry 320 320 640 480
            -- full scaled region: x 0..320, y 40..280 in letterbox space
            out = unletterboxBox lb (Box 0 40 320 240)
        out @?= Box 0 0 640 480,
      testGroup
        "properties"
        [ testProperty "nms is idempotent" prop_nmsIdempotent,
          testProperty "nms output is a subset of its input" prop_nmsSubset,
          testProperty "decode respects threshold + class filter" prop_decodeFilters
        ]
    ]

-- | Hand-built @[1, 84, 3]@ tensor:
--   anchor 0 → class 0 @ 0.9 (person, kept)
--   anchor 1 → class 5 @ 0.5 (bus, kept)
--   anchor 2 → class 4 @ 0.9 (airplane, filtered out by defaults)
goldenTensor :: Tensor
goldenTensor =
  Tensor
    { tensorShape = [1, 84, 3],
      tensorData = VS.generate (84 * 3) value
    }
  where
    value i =
      let (channel, anchor) = i `divMod` 3
       in case (channel, anchor) of
            (0, 0) -> 100
            (1, 0) -> 50
            (2, 0) -> 20
            (3, 0) -> 10
            (0, 1) -> 200
            (1, 1) -> 100
            (2, 1) -> 30
            (3, 1) -> 30
            (0, 2) -> 10
            (1, 2) -> 10
            (2, 2) -> 5
            (3, 2) -> 5
            (c, 0) | c == 4 + 0 -> 0.9
            (c, 1) | c == 4 + 5 -> 0.5
            (c, 2) | c == 4 + 4 -> 0.9
            (c, _) | c >= 4 -> 0.1
            _ -> 0

instance Arbitrary Detection where
  arbitrary =
    Detection
      <$> (Box <$> choose (0, 320) <*> choose (0, 320) <*> choose (1, 320) <*> choose (1, 320))
      <*> choose (0, 79)
      <*> choose (0, 1)

prop_nmsIdempotent :: Property
prop_nmsIdempotent =
  forAll arbitrary $ \dets ->
    let once = nms 0.45 100 (V.fromList (dets :: [Detection]))
     in nms 0.45 100 once === once

prop_nmsSubset :: Property
prop_nmsSubset =
  forAll arbitrary $ \dets ->
    let input = dets :: [Detection]
        out = nms 0.45 100 (V.fromList input)
     in all (`elem` input) (V.toList out)

prop_decodeFilters :: Property
prop_decodeFilters =
  forAll (choose (1, 20)) $ \anchors ->
    forAll (vectorOf (84 * anchors) arbitrary) $ \raw ->
      let dat = VS.fromList (map abs (raw :: [Float]))
          tensor = Tensor {tensorShape = [1, 84, fromIntegral anchors], tensorData = dat}
          out = decode 0.35 defaultKeepClasses tensor
       in all
            (\d -> detScore d >= 0.35 && defaultKeepClasses (detClassId d))
            (V.toList out)
