{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Tests for "Hnvr.Core.Crypto".
--
-- Covers:
--   * @initKey@ rejects malformed input (non-base64, wrong length).
--   * @generateKey@ output always round-trips through @initKey@.
--   * @encryptText@ \/ @decryptText@ round-trip for arbitrary Text.
--   * Auth tag is verified — flipping any byte in the ciphertext (which
--     includes the appended 16-byte GCM tag) makes @decryptText@ throw.
--   * Decrypting with a wrong nonce fails auth.
module Hnvr.Core.CryptoSpec (tests) where

import Control.Exception (SomeException, try)
import Data.Bits (complement)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Either (isLeft)
import Data.Text (Text)
import qualified Data.Text as T
import Hnvr.Core.Crypto
  ( Key (..),
    decryptText,
    encryptText,
    generateKey,
    initKey,
  )
import Test.QuickCheck
  ( Arbitrary (arbitrary),
    Property,
    generate,
  )
import Test.QuickCheck.Monadic (assert, monadicIO, run)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)
import Test.Tasty.QuickCheck (testProperty)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Crypto"
    [ testGroup
        "initKey"
        [ testCase "rejects non-base64 input" $
            assertEqual
              "non-base64 → Nothing"
              Nothing
              (initKey "!!! not base64 !!! not base64 !!!"),
          testCase "rejects base64 decoding to wrong length" $
            assertEqual
              "12-byte decode → Nothing"
              Nothing
              -- "AAAAAAAAAAAAAAAA" (16 base64 chars) decodes to 12 zero bytes.
              (initKey "AAAAAAAAAAAAAAAA"),
          testCase "accepts generateKey output" $ do
            keyB64 <- generateKey
            assertBool "generateKey output must be accepted by initKey" $
              case initKey keyB64 of
                Nothing -> False
                Just _ -> True
        ],
      testProperty "generateKey round-trips through initKey" prop_generateKeyRoundTrip,
      testProperty "encryptText/decryptText round-trip" prop_encryptDecryptRoundTrip,
      testProperty "byte-flip in ciphertext fails auth" prop_bitFlipFailsAuth,
      testProperty "wrong nonce fails auth" prop_wrongNonceFailsAuth
    ]

-- | @generateKey@ output should always be a valid key for @initKey@,
-- and the decoded key is exactly 32 bytes (AES-256).
prop_generateKeyRoundTrip :: Property
prop_generateKeyRoundTrip =
  monadicIO $ do
    keyB64 <- run generateKey
    case initKey keyB64 of
      Nothing -> assert False
      Just (Key bytes) -> assert (B.length bytes == 32)

-- | Encrypting then decrypting with the same key yields the original text.
-- Takes a 'String' (QuickCheck has a built-in 'Arbitrary String'); converts
-- to 'Text' for the round-trip.
prop_encryptDecryptRoundTrip :: String -> Property
prop_encryptDecryptRoundTrip plaintextStr =
  monadicIO $ do
    let plaintext = T.pack plaintextStr
    key <- run randomKey
    (ct, nonce) <- run (encryptText key plaintext)
    recovered <- run (decryptText key ct nonce)
    assert (recovered == plaintext)

-- | Flipping any single byte of the ciphertext (which includes the
-- appended 16-byte auth tag) must break GCM auth.
prop_bitFlipFailsAuth :: String -> Int -> Property
prop_bitFlipFailsAuth plaintextStr idx' =
  monadicIO $ do
    let plaintext = T.pack plaintextStr
    key <- run randomKey
    (ct, nonce) <- run (encryptText key plaintext)
    let len = B.length ct
        idx = idx' `mod` len
        flippedByte = complement (B.index ct idx)
        flipped =
          B.take idx ct
            <> B.singleton flippedByte
            <> B.drop (idx + 1) ct
    res <- run (try (decryptText key flipped nonce) :: IO (Either SomeException Text))
    assert (isLeft res)

-- | Decrypting with a different random nonce must fail auth.
prop_wrongNonceFailsAuth :: String -> Property
prop_wrongNonceFailsAuth plaintextStr =
  monadicIO $ do
    let plaintext = T.pack plaintextStr
    key <- run randomKey
    (ct, goodNonce) <- run (encryptText key plaintext)
    badNonce <- run (differentBytes 12 goodNonce)
    res <- run (try (decryptText key ct badNonce) :: IO (Either SomeException Text))
    assert (isLeft res)

-- ---- helpers -------------------------------------------------------

randomKey :: IO Key
randomKey = do
  keyB64 <- generateKey
  case initKey keyB64 of
    Just k -> pure k
    Nothing -> fail "initKey rejected its own generateKey output"

-- | @n@ random bytes, guaranteed to differ from @avoid@.
differentBytes :: Int -> ByteString -> IO ByteString
differentBytes n avoid = go
  where
    go = do
      bs <- B.pack <$> generate (sequence [arbitrary | _ <- [1 .. n]])
      if bs == avoid then go else pure bs
