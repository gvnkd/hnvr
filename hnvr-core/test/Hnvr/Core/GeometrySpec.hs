{-# LANGUAGE OverloadedStrings #-}

-- hlint-ignore: Functor law hints are intentional — these tests assert
-- the laws hold. Silence the "use id" / "use fmap composition" hints.
{-# HLINT ignore "Functor law" #-}

-- | Tests for "Hnvr.Core.Geometry".
--
-- Covers the @Functor@, @Foldable@, @Traversable@ laws for 'Box a' and
-- the @Functor@ identity for 'V2 a'. These classes are derived in the
-- source; the property suite guards against an accidental drop in a
-- future refactor.
module Hnvr.Core.GeometrySpec (tests) where

import Hnvr.Core.Geometry (Box (..), V2 (..))
import Test.QuickCheck
  ( Arbitrary (arbitrary),
    CoArbitrary,
    Fun,
    Function,
    Property,
    applyFun,
    (===),
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck (testProperty)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Geometry"
    [ testGroup
        "Box Functor laws"
        [ testProperty "fmap id = id" prop_boxFunctorIdentity,
          testProperty "fmap (f . g) = fmap f . fmap g" prop_boxFunctorComposition
        ],
      testGroup
        "Box Foldable"
        [ testProperty "foldr matches list fold" prop_boxFoldr,
          testProperty "length = 4" prop_boxLength
        ],
      testGroup
        "Box Traversable"
        [ testProperty "traverse Just = Just" prop_boxTraverseJust
        ],
      testGroup
        "V2 Functor"
        [ testProperty "fmap id = id" prop_v2FunctorIdentity
        ]
    ]

-- ---- Box Functor ---------------------------------------------------

prop_boxFunctorIdentity :: Box Int -> Property
prop_boxFunctorIdentity b = fmap id b === b

prop_boxFunctorComposition :: Fun Int Int -> Fun Int Int -> Box Int -> Property
prop_boxFunctorComposition f g b =
  fmap (applyFun f . applyFun g) b === fmap (applyFun f) (fmap (applyFun g) b)

-- ---- Box Foldable --------------------------------------------------

prop_boxFoldr :: Box Int -> Property
prop_boxFoldr b =
  foldr (:) [] b === [bxX b, bxY b, bxW b, bxH b]

prop_boxLength :: Box Int -> Property
prop_boxLength b = length b === 4

-- ---- Box Traversable ----------------------------------------------

prop_boxTraverseJust :: Box Int -> Property
prop_boxTraverseJust b = traverse Just b === Just b

-- ---- V2 Functor ----------------------------------------------------

prop_v2FunctorIdentity :: V2 Int -> Property
prop_v2FunctorIdentity v = fmap id v === v

-- ---- QuickCheck instances ------------------------------------------

instance (Arbitrary a) => Arbitrary (Box a) where
  arbitrary = Box <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary

instance (Arbitrary a) => Arbitrary (V2 a) where
  arbitrary = V2 <$> ((,) <$> arbitrary <*> arbitrary)
