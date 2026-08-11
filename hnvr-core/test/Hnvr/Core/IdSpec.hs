{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.Id".
module Hnvr.Core.IdSpec (tests) where

import qualified Data.ByteString as BS
import qualified Data.Text as T
import Hnvr.Core.Id (Sha256 (..), sha256FromHex, sha256ToHex)
import Test.QuickCheck
  ( Arbitrary (arbitrary),
    Property,
    vectorOf,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)
import Test.Tasty.QuickCheck (testProperty, (===))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Id"
    [ testGroup
        "sha256 hex roundtrip"
        [ testProperty "sha256FromHex . sha256ToHex = Just" prop_sha256RoundTrip,
          testCase "rejects 63-char input" $
            assertEqual
              "wrong length → Nothing"
              Nothing
              (sha256FromHex (T.replicate 63 "a")),
          testCase "rejects 65-char input" $
            assertEqual
              "wrong length → Nothing"
              Nothing
              (sha256FromHex (T.replicate 65 "a")),
          testCase "rejects non-hex 64-char input" $
            assertEqual
              "non-hex → Nothing"
              Nothing
              (sha256FromHex (T.replicate 32 "z0")),
          testCase "encodes known bytes lowercase" $
            let bs = Sha256 (BS.replicate 32 0xAB)
             in assertEqual
                  "hex"
                  (T.replicate 32 "ab")
                  (sha256ToHex bs)
        ]
    ]

-- | For any 32-byte Sha256, @sha256FromHex (sha256ToHex s) == Just s@.
prop_sha256RoundTrip :: Sha256 -> Property
prop_sha256RoundTrip s =
  sha256FromHex (sha256ToHex s) === Just s

-- QuickCheck instance for @Sha256@ — orphans are fine in test suites.
instance Arbitrary Sha256 where
  arbitrary = Sha256 . BS.pack <$> vectorOf 32 arbitrary
