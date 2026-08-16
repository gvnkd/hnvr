{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | DVRIP ("Sofia") socket client for XM-firmware cameras — the
-- management path where ONVIF is decorative (cam-198 family). Covers
-- the config-sync subset: login, GetConfig/SetConfig of
-- @Simplify.Encode@. See @Hnvr.Core.Dvrip@ for the protocol recap and
-- the pure framing/hash/drift logic.
--
-- Sessions are short-lived: connect → login → get/set → close. No
-- keepalive loop (the camera drops idle sessions after AliveInterval;
-- we don't hold them that long).
module Hnvr.Dvrip.Client
  ( DvripCreds (..),
    DvripError (..),
    dvripGetEncode,
    dvripSetEncode,
  )
where

import Control.Exception (SomeException, bracket, try)
import Data.Aeson (Value (..), (.:), (.=))
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KM
import qualified Data.Aeson.Types as Aeson (Pair, parseMaybe)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BL
import Data.Char (isDigit)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Word (Word16, Word32)
import Hnvr.Core.Dvrip
import qualified Network.Socket as Sock
import qualified Network.Socket.ByteString as NBS
import System.Timeout (timeout)

data DvripCreds = DvripCreds
  { dcUser :: !Text,
    dcPass :: !Text
  }
  deriving stock (Eq, Show)

data DvripError
  = DvripTransport Text
  | DvripAuth Int
  | DvripCamera Int Text
  | DvripParse Text
  deriving stock (Eq, Show)

-- | Login, run, close. The action gets a 'Session'.
withSession ::
  DvripCreds -> Text -> Int -> (Session -> IO (Either DvripError a)) -> IO (Either DvripError a)
withSession creds host port action = do
  res <- open
  case res of
    Left e -> pure (Left e)
    Right sess -> bracket (pure sess) (Sock.close . sessSock) action
  where
    open = do
      eSock <- try $ do
        addr : _ <- Sock.getAddrInfo (Just hints) (Just (T.unpack host)) (Just (show port))
        mSock <- timeout 10000000 $ do
          s <- Sock.socket (Sock.addrFamily addr) Sock.Stream Sock.defaultProtocol
          Sock.connect s (Sock.addrAddress addr)
          pure s
        case mSock of
          Nothing -> ioError (userError "dvrip: connect timeout (10s)")
          Just s -> pure s
      case (eSock :: Either SomeException Sock.Socket) of
        Left e -> pure (Left (DvripTransport (T.pack (show e))))
        Right sock -> do
          eLogin <- doLogin sock
          pure (fmap (Session sock) eLogin)
    hints = Sock.defaultHints {Sock.addrSocketType = Sock.Stream}
    doLogin sock = do
      let body =
            Aeson.encode
              ( Aeson.object
                  [ "EncryptType" .= ("MD5" :: Text),
                    "LoginType" .= ("DVRIP-Web" :: Text),
                    "PassWord" .= sofiaHash (dcPass creds),
                    "UserName" .= dcUser creds
                  ]
              )
      eResp <- roundTrip sock 0 msgLogin (BL.toStrict body)
      pure $ case eResp of
        Left e -> Left e
        Right v -> case Aeson.parseMaybe (Aeson.withObject "login" (\o -> (,) <$> o .: "Ret" <*> o .: "SessionID")) v of
          Just (ret, sidHex)
            | ret == 100 || ret == (515 :: Int) ->
                case readHexWord32 (sidHex :: Text) of
                  Just sid -> Right sid
                  Nothing -> Left (DvripParse ("bad SessionID: " <> sidHex))
          Just (ret, _) -> Left (DvripAuth ret)
          Nothing -> Left (DvripParse "malformed login response")

data Session = Session
  { sessSock :: !Sock.Socket,
    sessId :: !Word32
  }

-- | Send one packet, read one response packet, decode the JSON payload
-- (minus the 2-byte tail). XM cameras sometimes hold the socket open
-- without answering (login flood, wedged handler) — the whole
-- round-trip is bounded by a 10 s timeout so a poll can't wedge
-- (network's RecvTimeOut sockopt is broken on Linux/x86_64 with
-- network-3.2 — 'invalid argument' — hence System.Timeout).
roundTrip :: Sock.Socket -> Word32 -> Word16 -> ByteString -> IO (Either DvripError Value)
roundTrip sock session msgid payload = do
  mResp <- timeout 10000000 roundTripIO
  pure $ case mResp of
    Nothing -> Left (DvripTransport "timeout (10s)")
    Just r -> r
  where
    roundTripIO = do
      eResp <- try $ do
        NBS.sendAll sock (buildPacket session 0 msgid payload)
        hdr <- recvExact sock 20
        case parseHeader hdr of
          Nothing -> pure (Left (DvripParse "bad header"))
          Just (_, _, _, len) -> do
            body <- recvExact sock (fromIntegral len)
            let jsonBytes = BS.take (BS.length body - 2) body
            case Aeson.eitherDecodeStrict jsonBytes of
              Left err -> pure (Left (DvripParse (T.pack err)))
              Right v -> pure (Right v)
      pure $ case (eResp :: Either SomeException (Either DvripError Value)) of
        Left e -> Left (DvripTransport (T.pack (show e)))
        Right r -> r

recvExact :: Sock.Socket -> Int -> IO ByteString
recvExact sock n = go []
  where
    go acc
      | sum (map BS.length acc) >= n = pure (BS.concat (reverse acc))
      | otherwise = do
          chunk <- NBS.recv sock (n - sum (map BS.length acc))
          if BS.null chunk
            then pure (BS.concat (reverse acc))
            else go (chunk : acc)

sidText :: Word32 -> Text
sidText sid = "0x" <> T.toLower (hex8 sid)
  where
    hex8 v = T.pack (pad (toHex v))
    pad s = replicate (8 - length s) '0' ++ s
    toHex 0 = "0"
    toHex v = go v ""
    go 0 acc = acc
    go v acc = go (v `div` 16) (hexDigits !! fromIntegral (v `mod` 16) : acc)
    hexDigits = "0123456789abcdef"

-- | Read Simplify.Encode from the camera.
dvripGetEncode :: DvripCreds -> Text -> Int -> IO (Either DvripError SimplifyEncode)
dvripGetEncode creds host port =
  withSession creds host port $ \sess -> do
    eResp <- configRoundTrip sess msgGetConfig (object' [])
    pure $ case eResp of
      Left e -> Left e
      Right v -> case KM.lookup "Simplify.Encode" (objMap v) of
        Nothing -> Left (DvripParse "no Simplify.Encode in response")
        Just sv -> case Aeson.fromJSON sv of
          Aeson.Success se -> Right se
          Aeson.Error err -> Left (DvripParse (T.pack err))

-- | Write Simplify.Encode (full structure — the camera merges nothing;
-- send the complete get-modify-set result).
dvripSetEncode :: DvripCreds -> Text -> Int -> SimplifyEncode -> IO (Either DvripError ())
dvripSetEncode creds host port se =
  withSession creds host port $ \sess -> do
    eResp <- configRoundTrip sess msgSetConfig (Aeson.toJSON se)
    pure $ case eResp of
      Left e -> Left e
      Right v -> case Aeson.parseMaybe (Aeson.withObject "ret" (.: "Ret")) v of
        Just ret | ret == 100 || ret == (515 :: Int) -> Right ()
        Just ret -> Left (DvripCamera ret (T.pack (show v)))
        Nothing -> Left (DvripParse "malformed set response")

configRoundTrip :: Session -> Word16 -> Value -> IO (Either DvripError Value)
configRoundTrip sess msgid payload =
  roundTrip
    (sessSock sess)
    (sessId sess)
    msgid
    ( BL.toStrict
        ( Aeson.encode
            ( Aeson.object
                [ "Name" .= ("Simplify.Encode" :: Text),
                  "SessionID" .= sidText (sessId sess),
                  "Simplify.Encode" .= payload
                ]
            )
        )
    )

object' :: [Aeson.Pair] -> Value
object' = Aeson.object

objMap :: Value -> KM.KeyMap Value
objMap (Object o) = o
objMap _ = mempty

readHexWord32 :: Text -> Maybe Word32
readHexWord32 t =
  let s = T.unpack (fromMaybe t (T.stripPrefix "0x" (T.toLower t)))
      hexVal c
        | isDigit c = fromEnum c - fromEnum '0'
        | otherwise = fromEnum c - fromEnum 'a' + 10
      go acc c = acc * 16 + fromIntegral (hexVal c)
   in if null s || any (`notElem` ("0123456789abcdef" :: String)) s
        then Nothing
        else Just (foldl go 0 s)
