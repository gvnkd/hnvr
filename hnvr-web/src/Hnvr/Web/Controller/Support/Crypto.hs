{-# LANGUAGE OverloadedStrings #-}

-- | Crypto helpers for the Cameras controller.
--
-- Reads the AES-256 data key from @HNVR_DATA_KEY@ (base64-encoded 32
-- bytes, provisioned via sops-nix in production). Encryption happens on
-- Create/Update; decryption on Probe (to reconstruct the full RTSP URL
-- with credentials that ffprobe needs).
--
-- Throws 'userError' at the action level if @HNVR_DATA_KEY@ is missing
-- or malformed — the leader is unsafe to run without it.
module Hnvr.Web.Controller.Support.Crypto
  ( encryptPassword,
    decryptPassword,
    requireKey,
  )
where

import Control.Exception (throwIO)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC (pack)
import Data.Text (Text)
import qualified Data.Text as T
import Database.PostgreSQL.Simple.Types (Binary (..))
import Hnvr.Core.Crypto (Key, decryptText, encryptText, initKey)
import qualified Hnvr.Core.Crypto as Crypto
import System.Environment (lookupEnv)

-- | Read and validate the data key from the environment. Throws if
-- missing or malformed. Called per-action — cheap relative to the
-- actual encrypt/decrypt.
requireKey :: IO Key
requireKey = do
  mKeyEnv <- lookupEnv "HNVR_DATA_KEY"
  case mKeyEnv of
    Nothing -> throwIO (userError "HNVR_DATA_KEY not set; cannot encrypt/decrypt camera passwords")
    Just k -> case initKey (BC.pack k) of
      Nothing -> throwIO (userError "HNVR_DATA_KEY is not a valid base64-encoded 32-byte AES key")
      Just key -> pure key

-- | Encrypt a plaintext password for storage. Returns the
-- (password_enc, password_nonce) pair as 'Binary' 'ByteString' values
-- ready to write into the cameras row.
encryptPassword :: Text -> IO (Binary ByteString, Binary ByteString)
encryptPassword plaintext = do
  key <- requireKey
  (ct, nonce) <- encryptText key plaintext
  pure (Binary ct, Binary nonce)

-- | Decrypt a stored password. Returns 'Nothing' if the row has no
-- encrypted password stored (e.g. camera with no auth).
decryptPassword :: Maybe (Binary ByteString) -> Maybe (Binary ByteString) -> IO (Maybe Text)
decryptPassword Nothing _ = pure Nothing
decryptPassword _ Nothing = pure Nothing
decryptPassword (Just (Binary ct)) (Just (Binary nonce)) = do
  key <- requireKey
  Just <$> decryptText key ct nonce
