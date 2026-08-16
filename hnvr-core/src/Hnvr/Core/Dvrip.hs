{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | XM "Sofia" / DVRIP protocol — pure parts: packet framing, the sofia
-- password hash, the Simplify.Encode config model, and drift detection
-- against the sparse 'DesiredVideo'. No IO here; the socket client is
-- @Hnvr.Dvrip.Client@ (hnvr-ptz).
--
-- Protocol recap (from the reference python-dvr implementation):
--
--   * TCP :34567. Packet = 20-byte header @BB2xII2xHI@ (magic 0xFF,
--     version 0, session LE32, sequence LE32, msgid LE16, payload
--     length LE32) + JSON payload + "\x0a\x00" tail.
--   * Login: msgid 1000 with the sofia-hashed password; the response
--     carries the session id used in all subsequent packets.
--   * GetConfig: msgid 1042 {"Name": cmd, "SessionID": "0x%08X"}.
--   * SetConfig: msgid 1040 {"Name": cmd, "SessionID": ..., cmd: data}.
--
-- XM quirk: resolution is a named enum ("6M", "D1", "QVGA"...), not
-- width/height integers. 'resolutionTable' maps the names this
-- firmware family actually uses; unknown names leave resolution
-- unmanaged rather than guessing.
--
-- XM quirk: GOP is in SECONDS (keyframe interval), not frames —
-- govLength in frames = GOP × FPS.
module Hnvr.Core.Dvrip
  ( sofiaHash,
    buildPacket,
    parseHeader,
    msgLogin,
    msgKeepAlive,
    msgSetConfig,
    msgGetConfig,
    EncodeFormat (..),
    SimplifyEncode (..),
    resolutionToName,
    resolutionFromName,
    dvripVideoDrift,
    applyDesiredVideo,
  )
where

import Crypto.Hash (Digest, MD5 (..), hash)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.=))
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.ByteString.Builder (byteString, toLazyByteString, word16LE, word32LE, word8)
import qualified Data.ByteString.Lazy as BL
import Data.List (find)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Data.Word (Word16, Word32)
import GHC.Generics (Generic)
import Hnvr.Core.Onvif (DesiredVideo (..), DriftItem (..), VideoEncoding (..), videoEncodingText)

-- | msgids we use.
msgLogin, msgKeepAlive, msgSetConfig, msgGetConfig :: Word16
msgLogin = 1000
msgKeepAlive = 1006
msgSetConfig = 1040
msgGetConfig = 1042

-- | The "sofia hash": MD5(password) raw digest, then fold byte pairs
-- (even,odd) into @sum mod 62@ indexed into @[0-9A-Za-z]@ → 8 chars.
sofiaHash :: Text -> Text
sofiaHash pw =
  let d = BA.convert (hash (T.encodeUtf8 pw) :: Digest MD5) :: ByteString
      evens = BS.unpack (BS.pack [BS.index d i | i <- [0, 2 .. 14]])
      odds = BS.unpack (BS.pack [BS.index d i | i <- [1, 3 .. 15]])
      chars = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
   in T.pack [chars !! ((fromIntegral e + fromIntegral o) `mod` 62) | (e, o) <- zip evens odds]

-- | Build one v0 packet: header + payload + "\x0a\x00" tail (the
-- length field covers payload + tail).
buildPacket :: Word32 -> Word32 -> Word16 -> ByteString -> ByteString
buildPacket session seqNum msgid payload =
  BL.toStrict . toLazyByteString $
    word8 0xFF
      <> word8 0x00
      <> word8 0x00
      <> word8 0x00
      <> word32LE session
      <> word32LE seqNum
      <> word8 0x00
      <> word8 0x00
      <> word16LE msgid
      <> word32LE (fromIntegral (BS.length payload + 2))
      <> byteString payload
      <> byteString "\x0a\x00"

-- | Parse a 20-byte response header → (session, sequence, msgid,
-- payloadLength). 'Nothing' if short or wrong magic.
parseHeader :: ByteString -> Maybe (Word32, Word32, Word16, Word32)
parseHeader bs
  | BS.length bs < 20 = Nothing
  | BS.index bs 0 /= 0xFF = Nothing
  | otherwise =
      Just
        ( le32 4,
          le32 8,
          fromIntegral (BS.index bs 14) + 256 * fromIntegral (BS.index bs 15),
          le32 16
        )
  where
    le32 o =
      fromIntegral (BS.index bs o)
        + 256 * fromIntegral (BS.index bs (o + 1))
        + 65536 * fromIntegral (BS.index bs (o + 2))
        + 16777216 * fromIntegral (BS.index bs (o + 3))

-- | One XM encode format block (MainFormat or ExtraFormat).
data EncodeFormat = EncodeFormat
  { efAudioEnable :: !Bool,
    efVideoEnable :: !Bool,
    efCompression :: !Text,
    efResolution :: !Text,
    efFps :: !Int,
    efBitRate :: !Int,
    -- | Keyframe interval in SECONDS (XM quirk).
    efGop :: !Int,
    efBitRateControl :: !Text,
    efQuality :: !Int,
    efVirtualGop :: !Int
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON EncodeFormat where
  toJSON f =
    object
      [ "AudioEnable" .= efAudioEnable f,
        "VideoEnable" .= efVideoEnable f,
        "Video"
          .= object
            [ "BitRate" .= efBitRate f,
              "BitRateControl" .= efBitRateControl f,
              "Compression" .= efCompression f,
              "FPS" .= efFps f,
              "GOP" .= efGop f,
              "Quality" .= efQuality f,
              "Resolution" .= efResolution f,
              "VirtualGOP" .= efVirtualGop f
            ]
      ]

instance FromJSON EncodeFormat where
  parseJSON = withObject "EncodeFormat" $ \o -> do
    v <- o .: "Video"
    EncodeFormat
      <$> o .: "AudioEnable"
      <*> o .: "VideoEnable"
      <*> v .: "Compression"
      <*> v .: "Resolution"
      <*> v .: "FPS"
      <*> v .: "BitRate"
      <*> v .: "GOP"
      <*> v .: "BitRateControl"
      <*> v .: "Quality"
      <*> v .: "VirtualGOP"

-- | Simplify.Encode payload: one-element array with Main + Extra.
data SimplifyEncode = SimplifyEncode
  { seMain :: !EncodeFormat,
    seExtra :: !EncodeFormat
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON SimplifyEncode where
  toJSON (SimplifyEncode m e) = toJSON [object ["MainFormat" .= m, "ExtraFormat" .= e]]

instance FromJSON SimplifyEncode where
  parseJSON v = do
    xs <- parseJSON v
    case xs of
      [x] -> parseObj x
      _ -> fail "SimplifyEncode: expected one-element array"
    where
      parseObj = withObject "SimplifyEncode" $ \o ->
        SimplifyEncode <$> o .: "MainFormat" <*> o .: "ExtraFormat"

-- | XM resolution enum ↔ (width, height). "QVGA" is 640×360 on the
-- GK7205V300 firmware (verified against the live stream), NOT the
-- classic 320×240. Unknown names: 'resolutionFromName' returns
-- 'Nothing', and 'resolutionToName' returns 'Nothing' so the field
-- stays unmanaged.
resolutionTable :: [(Text, (Int, Int))]
resolutionTable =
  [ ("6M", (3072, 2048)),
    ("5M", (2592, 1944)),
    ("4M", (2560, 1440)),
    ("3M", (2304, 1296)),
    ("1080P", (1920, 1080)),
    ("960P", (1280, 960)),
    ("720P", (1280, 720)),
    ("960H", (960, 576)),
    ("D1", (704, 576)),
    ("QVGA", (640, 360)),
    ("VGA", (640, 480)),
    ("CIF", (352, 288)),
    ("QCIF", (176, 144))
  ]

resolutionFromName :: Text -> Maybe (Int, Int)
resolutionFromName n = lookup n resolutionTable

resolutionToName :: (Int, Int) -> Maybe Text
resolutionToName wh = fst <$> find (\(_, wh') -> wh' == wh) resolutionTable

-- | Sparse desired video config → drift against one encode format.
-- Width/height compare via the resolution name mapping; gov compares
-- frames vs GOP×FPS.
dvripVideoDrift :: Text -> DesiredVideo -> EncodeFormat -> [DriftItem]
dvripVideoDrift cfgName d f =
  drift "encoding" (videoEncodingText <$> dvEncoding d) (compressionText (efCompression f))
    <> resDrift
    <> drift "fps" (showT <$> dvFps d) (showT (efFps f))
    <> drift "bitrateKbps" (showT <$> dvBitrateKbps d) (showT (efBitRate f))
    <> drift "govLength" (showT <$> dvGovLength d) (showT (efGop f * efFps f))
  where
    resDrift = case (resolutionFromName (efResolution f), dvWidth d, dvHeight d) of
      (Just _, Just w, Just h)
        | resolutionFromName (efResolution f) == Just (w, h) -> []
        | otherwise ->
            [ DriftItem
                cfgName
                "resolution"
                (showT w <> "x" <> showT h)
                (efResolution f <> maybe "" (\(ow, oh) -> " (" <> showT ow <> "x" <> showT oh <> ")") (resolutionFromName (efResolution f)))
            ]
      _ -> []
    drift field mDesired observed = case mDesired of
      Nothing -> []
      Just d'
        | d' == observed -> []
        | otherwise -> [DriftItem cfgName field d' observed]
    showT = T.pack . show

compressionText :: Text -> Text
compressionText "H.264" = "H264"
compressionText "H.265" = "H265"
compressionText t = t

-- | Apply sparse desired values onto an encode format. Unmanaged
-- fields keep current values. Resolution applies only when the
-- desired (w,h) has a known XM name; encoding maps H264/H265 to the
-- XM dotted form. GOP seconds = ceil(govFrames / fps).
applyDesiredVideo :: DesiredVideo -> EncodeFormat -> EncodeFormat
applyDesiredVideo d f =
  f
    { efCompression = fromMaybe (efCompression f) (dvEncoding d >>= xmCompression),
      efResolution = fromMaybe (efResolution f) (resName =<< dvWidth d),
      efFps = fromMaybe (efFps f) (dvFps d),
      efBitRate = fromMaybe (efBitRate f) (dvBitrateKbps d),
      efGop = maybe (efGop f) (gopSec (efFps f)) (dvGovLength d)
    }
  where
    xmCompression VEncH264 = Just "H.264"
    xmCompression VEncH265 = Just "H.265"
    xmCompression _ = Nothing
    resName w = dvHeight d >>= \h -> resolutionToName (w, h)
    gopSec fps frames = max 1 (ceiling (fromIntegral frames / fromIntegral fps :: Double))
