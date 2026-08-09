{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | AES-256-GCM encryption for camera passwords.
--
-- Schema: @cameras.password_enc BYTEA@ + @cameras.password_nonce BYTEA@
-- (96-bit GCM nonce, 128-bit auth tag appended to ciphertext). The data
-- key comes from @HNVR_DATA_KEY@ (base64-encoded 32 bytes), provisioned
-- via sops-nix in production. Dev/test uses a generated key from
-- @openssl rand -base64 32@.
--
-- Storage format: @password_enc = <ciphertext> || <auth_tag>@ where
-- auth_tag is the 16-byte GCM tag. @password_nonce@ is the raw 12-byte
-- nonce, unique per row.
module Hnvr.Core.Crypto
  ( Key (..),
    initKey,
    encryptText,
    decryptText,
    generateKey,
  )
where

import Control.Exception (throwIO)
import Crypto.Cipher.AES (AES256)
import Crypto.Cipher.Types
  ( AEAD (..),
    AEADMode (..),
    AuthTag (..),
    aeadAppendHeader,
    aeadDecrypt,
    aeadEncrypt,
    aeadFinalize,
    aeadInit,
    cipherInit,
  )
import Crypto.Error (CryptoFailable (..))
import Crypto.Random (getRandomBytes)
import Data.ByteArray (convert)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64 as B64
import Data.Text (Text)
import qualified Data.Text.Encoding as TE

-- | AES-256 data key (32 bytes raw).
newtype Key = Key ByteString
  deriving stock (Eq, Show)

-- | Decode a base64-encoded 32-byte key. Returns 'Nothing' on malformed
-- input or wrong length.
initKey :: ByteString -> Maybe Key
initKey b64 =
  case B64.decode b64 of
    Left _ -> Nothing
    Right bs
      | B.length bs == 32 -> Just (Key bs)
      | otherwise -> Nothing

-- | Generate a fresh random key. For dev/test only — production reads
-- from @HNVR_DATA_KEY@ via sops-nix. The returned base64-encoded key
-- can be put in @.env@ or a sops secret.
generateKey :: IO ByteString
generateKey = B64.encode <$> getRandomBytes 32

-- | Encrypt a Text with AES-256-GCM. Returns @(ciphertext_with_tag, nonce)@
-- where the ciphertext has the 16-byte auth tag appended and the nonce is
-- the raw 12-byte GCM nonce (must be stored alongside for decryption).
encryptText :: Key -> Text -> IO (ByteString, ByteString)
encryptText (Key kb) plaintext = do
  cipher <- initCipher kb
  nonce <- getRandomBytes 12
  aead <- initAead cipher nonce
  let plainBs = TE.encodeUtf8 plaintext
      aead1 = aeadAppendHeader aead B.empty
      (ctBs, aead2) = aeadEncrypt aead1 plainBs
      AuthTag tagBs = aeadFinalize aead2 16
      ctBs' :: ByteString = convert ctBs
      tagBs' :: ByteString = convert tagBs
  pure (ctBs' <> tagBs', nonce)

-- | Decrypt a Text with AES-256-GCM. Throws on auth failure (corrupt
-- ciphertext, wrong key, or wrong nonce).
decryptText :: Key -> ByteString -> ByteString -> IO Text
decryptText (Key kb) ciphertextWithTag nonce = do
  cipher <- initCipher kb
  aead <- initAead cipher nonce
  let (ct, tag) = B.splitAt (B.length ciphertextWithTag - 16) ciphertextWithTag
      aead1 = aeadAppendHeader aead B.empty
      (plainBs, aead2) = aeadDecrypt aead1 ct
      AuthTag computedTag = aeadFinalize aead2 16
      computedTagBs :: ByteString = convert computedTag
  if computedTagBs == tag
    then case TE.decodeUtf8' (convert plainBs :: ByteString) of
      Left err -> throwIO (userError ("UTF-8 decode failed: " <> show err))
      Right t -> pure t
    else throwIO (userError "AES-GCM auth failed (wrong key/nonce/ciphertext)")

initCipher :: ByteString -> IO AES256
initCipher kb =
  case cipherInit kb of
    CryptoFailed err -> throwIO (userError ("cipherInit failed: " <> show err))
    CryptoPassed c -> pure c

initAead :: AES256 -> ByteString -> IO (AEAD AES256)
initAead cipher nonce =
  case aeadInit AEAD_GCM cipher nonce of
    CryptoFailed err -> throwIO (userError ("aeadInit failed: " <> show err))
    CryptoPassed a -> pure a
