{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Round-trip test for Hnvr.Core.Crypto.
--
-- Usage:
--   hnvr-crypto-test               # generates a key, prints it, round-trips
--   HNVR_DATA_KEY=<b64> hnvr-crypto-test   # uses provided key
module Main (main) where

import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC (pack, unpack)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Hnvr.Core.Crypto
import System.Environment (lookupEnv)
import System.Exit (exitFailure)
import System.IO (hPutStrLn, stderr)

main :: IO ()
main = do
  mKeyEnv <- lookupEnv "HNVR_DATA_KEY"
  keyB64 <- case mKeyEnv of
    Just k -> pure (BC.pack k)
    Nothing -> do
      g <- generateKey
      hPutStrLn stderr ("[crypto-test] no HNVR_DATA_KEY; generated (use this in production): " <> BC.unpack g)
      pure g
  case initKey keyB64 of
    Nothing -> dieErr ("HNVR_DATA_KEY is not a valid base64-encoded 32-byte key (got " <> BC.unpack keyB64 <> ")")
    Just key -> roundTrip key

roundTrip :: Key -> IO ()
roundTrip key = do
  let sample :: Text = "rtsp://admin:supersecret@192.168.0.197:554/stream"
  TIO.hPutStrLn stderr ("[crypto-test] sample plaintext: " <> sample)
  (ct, nonce) <- encryptText key sample
  hPutStrLn stderr ("[crypto-test] ciphertext+tag length: " <> show (B.length ct) <> " bytes")
  hPutStrLn stderr ("[crypto-test] nonce length: " <> show (B.length nonce) <> " bytes")
  recovered <- decryptText key ct nonce
  if recovered == sample
    then TIO.hPutStrLn stderr ("[crypto-test] OK round-trip: " <> recovered)
    else do
      TIO.hPutStrLn stderr ("[crypto-test] MISMATCH! expected: " <> sample)
      TIO.hPutStrLn stderr ("[crypto-test]             got: " <> recovered)
      exitFailure

dieErr :: String -> IO a
dieErr msg = hPutStrLn stderr msg >> exitFailure
