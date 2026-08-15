{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | ONVIF camera-config model: pure types + drift detection + capability
-- clamping. No IO here — the SOAP client lives in @Hnvr.Onvif.Client@
-- (hnvr-ptz), the poller in @Hnvr.Web.OnvifSyncer@ (hnvr-web).
--
-- Desired config is SPARSE: a 'Nothing' field means "unmanaged" — drift
-- ignores it and push leaves the camera's current value alone.
--
-- Vendor unit quirk: ONVIF says audio Bitrate is kbps and SampleRate is
-- kHz, but the Hikvision-OEM firmware (cam-196/197) reports raw bps/Hz
-- (64000 / 16000) while the XM firmware (cam-198) follows the spec
-- (128 / 8). 'normalizeBitrateKbps' / 'normalizeSampleRateKhz' fold both
-- into spec units; the client applies them at parse time so every
-- downstream consumer sees spec units.
module Hnvr.Core.Onvif
  ( AudioEncoding (..),
    VideoEncoding (..),
    AudioConfig (..),
    VideoConfig (..),
    DesiredAudio (..),
    DesiredVideo (..),
    DriftItem (..),
    audioDrift,
    videoDrift,
    normalizeBitrateKbps,
    normalizeSampleRateKhz,
    AudioOptions (..),
    VideoOptions (..),
    clampAudio,
    clampVideo,
    audioEncodingText,
    videoEncodingText,
    parseAudioEncoding,
    parseVideoEncoding,
    emptyDesiredAudio,
    emptyDesiredVideo,
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text (Text)
import qualified Data.Text as T
import GHC.Generics (Generic)

data AudioEncoding = EncG711 | EncG726 | EncAAC | EncOther Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data VideoEncoding = VEncH264 | VEncH265 | VEncJpeg | VEncOther Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

audioEncodingText :: AudioEncoding -> Text
audioEncodingText EncG711 = "G711"
audioEncodingText EncG726 = "G726"
audioEncodingText EncAAC = "AAC"
audioEncodingText (EncOther t) = t

videoEncodingText :: VideoEncoding -> Text
videoEncodingText VEncH264 = "H264"
videoEncodingText VEncH265 = "H265"
videoEncodingText VEncJpeg = "JPEG"
videoEncodingText (VEncOther t) = t

parseAudioEncoding :: Text -> AudioEncoding
parseAudioEncoding "G711" = EncG711
parseAudioEncoding "G726" = EncG726
parseAudioEncoding "AAC" = EncAAC
parseAudioEncoding t = EncOther t

parseVideoEncoding :: Text -> VideoEncoding
parseVideoEncoding "H264" = VEncH264
parseVideoEncoding "H265" = VEncH265
parseVideoEncoding "JPEG" = VEncJpeg
parseVideoEncoding t = VEncOther t

-- | One audio encoder configuration as reported by the camera.
-- Bitrate in kbps, sample rate in kHz (normalized at parse time).
data AudioConfig = AudioConfig
  { acToken :: !Text,
    acName :: !Text,
    -- | Needed to build a valid SetAudioEncoderConfiguration request.
    acUseCount :: !Int,
    acEncoding :: !AudioEncoding,
    acBitrateKbps :: !Int,
    acSampleRateKhz :: !Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | One video encoder configuration. Bitrate in kbps (BitrateLimit).
data VideoConfig = VideoConfig
  { vcToken :: !Text,
    vcName :: !Text,
    vcUseCount :: !Int,
    vcEncoding :: !VideoEncoding,
    vcWidth :: !Int,
    vcHeight :: !Int,
    -- | Quality 0..100 (vendor scale; informational only, never managed).
    vcQuality :: !Double,
    vcFps :: !Int,
    -- | RateControl EncodingInterval — preserved verbatim on push.
    vcEncodingInterval :: !Int,
    vcBitrateKbps :: !Int,
    vcGovLength :: !Int,
    -- | H264/H265 codec profile (e.g. "High") — preserved verbatim on push.
    vcCodecProfile :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Sparse desired audio config. 'Nothing' = unmanaged.
data DesiredAudio = DesiredAudio
  { daEncoding :: !(Maybe AudioEncoding),
    daBitrateKbps :: !(Maybe Int),
    daSampleRateKhz :: !(Maybe Int)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Sparse desired video config. 'Nothing' = unmanaged.
data DesiredVideo = DesiredVideo
  { dvEncoding :: !(Maybe VideoEncoding),
    dvWidth :: !(Maybe Int),
    dvHeight :: !(Maybe Int),
    dvFps :: !(Maybe Int),
    dvBitrateKbps :: !(Maybe Int),
    dvGovLength :: !(Maybe Int)
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

emptyDesiredAudio :: DesiredAudio
emptyDesiredAudio = DesiredAudio Nothing Nothing Nothing

emptyDesiredVideo :: DesiredVideo
emptyDesiredVideo = DesiredVideo Nothing Nothing Nothing Nothing Nothing Nothing

-- | One mismatched field between desired and observed.
data DriftItem = DriftItem
  { -- | Encoder config name the drift belongs to (e.g. "AudioMain").
    diConfig :: !Text,
    diField :: !Text,
    diDesired :: !Text,
    diObserved :: !Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

drift :: Text -> Text -> Maybe Text -> Text -> [DriftItem]
drift cfg field mDesired observed = case mDesired of
  Nothing -> []
  Just d
    | d == observed -> []
    | otherwise -> [DriftItem cfg field d observed]

audioDrift :: DesiredAudio -> AudioConfig -> [DriftItem]
audioDrift d a =
  drift (acName a) "encoding" (audioEncodingText <$> daEncoding d) (audioEncodingText (acEncoding a))
    <> drift (acName a) "bitrateKbps" (showT <$> daBitrateKbps d) (showT (acBitrateKbps a))
    <> drift (acName a) "sampleRateKhz" (showT <$> daSampleRateKhz d) (showT (acSampleRateKhz a))
  where
    showT = tshowI

videoDrift :: DesiredVideo -> VideoConfig -> [DriftItem]
videoDrift d v =
  drift (vcName v) "encoding" (videoEncodingText <$> dvEncoding d) (videoEncodingText (vcEncoding v))
    <> drift (vcName v) "width" (showT <$> dvWidth d) (showT (vcWidth v))
    <> drift (vcName v) "height" (showT <$> dvHeight d) (showT (vcHeight v))
    <> drift (vcName v) "fps" (showT <$> dvFps d) (showT (vcFps v))
    <> drift (vcName v) "bitrateKbps" (showT <$> dvBitrateKbps d) (showT (vcBitrateKbps v))
    <> drift (vcName v) "govLength" (showT <$> dvGovLength d) (showT (vcGovLength v))
  where
    showT = tshowI

tshowI :: Int -> Text
tshowI = T.pack . show

-- | Fold vendor-reported audio bitrate into kbps. Spec says kbps; the
-- Hikvision-OEM firmware reports bps (64000). Heuristic: anything above
-- 10000 is implausible as kbps for camera audio, so treat as bps.
normalizeBitrateKbps :: Int -> Int
normalizeBitrateKbps n
  | n > 10000 = round (fromIntegral n / 1000.0 :: Double)
  | otherwise = n

-- | Fold vendor-reported audio sample rate into kHz. Spec says kHz;
-- Hikvision-OEM reports Hz (16000). Anything above 1000 is Hz.
normalizeSampleRateKhz :: Int -> Int
normalizeSampleRateKhz n
  | n > 1000 = round (fromIntegral n / 1000.0 :: Double)
  | otherwise = n

-- | Audio encoder capabilities from GetAudioEncoderConfigurationOptions.
-- Empty lists mean the firmware didn't constrain the field (free choice).
data AudioOptions = AudioOptions
  { aoEncodings :: ![AudioEncoding],
    aoBitratesKbps :: ![Int],
    aoSampleRatesKhz :: ![Int]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

data VideoOptions = VideoOptions
  { voEncodings :: ![VideoEncoding],
    -- | Offered (width, height) pairs across all codec sections.
    voResolutions :: ![(Int, Int)],
    voFpsRange :: !(Maybe (Int, Int)),
    voBitrateRangeKbps :: !(Maybe (Int, Int)),
    voGovRange :: !(Maybe (Int, Int))
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON, FromJSON)

-- | Snap a desired audio config into what the camera offers. The result
-- is what push will actually send; fields the camera left unconstrained
-- pass through. Encoding falls back to the camera's current one when the
-- desired encoding isn't offered (we'd rather no-op than brick audio).
clampAudio :: AudioOptions -> AudioConfig -> DesiredAudio -> AudioConfig
clampAudio opts cur d =
  AudioConfig
    { acToken = acToken cur,
      acName = acName cur,
      acUseCount = acUseCount cur,
      acEncoding = pick (daEncoding d) (aoEncodings opts) (acEncoding cur),
      acBitrateKbps = nearestIn (daBitrateKbps d) (aoBitratesKbps opts) (acBitrateKbps cur),
      acSampleRateKhz = nearestIn (daSampleRateKhz d) (aoSampleRatesKhz opts) (acSampleRateKhz cur)
    }

clampVideo :: VideoOptions -> VideoConfig -> DesiredVideo -> VideoConfig
clampVideo opts cur d =
  VideoConfig
    { vcToken = vcToken cur,
      vcName = vcName cur,
      vcUseCount = vcUseCount cur,
      vcEncoding = pick (dvEncoding d) (voEncodings opts) (vcEncoding cur),
      vcWidth = w',
      vcHeight = h',
      vcQuality = vcQuality cur,
      vcFps = inRange (dvFps d) (voFpsRange opts) (vcFps cur),
      vcEncodingInterval = vcEncodingInterval cur,
      vcBitrateKbps = inRange (dvBitrateKbps d) (voBitrateRangeKbps opts) (vcBitrateKbps cur),
      vcGovLength = inRange (dvGovLength d) (voGovRange opts) (vcGovLength cur),
      vcCodecProfile = vcCodecProfile cur
    }
  where
    (w', h') = case (dvWidth d, dvHeight d) of
      (Just w, Just h)
        | null (voResolutions opts) -> (w, h)
        | (w, h) `elem` voResolutions opts -> (w, h)
        | otherwise -> nearestRes (w, h) (voResolutions opts)
      _ -> (vcWidth cur, vcHeight cur)

pick :: (Eq a) => Maybe a -> [a] -> a -> a
pick (Just x) offered fallback
  | null offered || x `elem` offered = x
  | otherwise = fallback
pick Nothing _ fallback = fallback

-- | Nearest offered value; unmanaged/out-of-list falls back to current.
nearestIn :: Maybe Int -> [Int] -> Int -> Int
nearestIn (Just x) offered fallback
  | null offered = x
  | x `elem` offered = x
  | otherwise = minimumByAbs x offered
nearestIn Nothing _ fallback = fallback

minimumByAbs :: Int -> [Int] -> Int
minimumByAbs x = foldr1 (\a b -> if abs (a - x) <= abs (b - x) then a else b)

inRange :: Maybe Int -> Maybe (Int, Int) -> Int -> Int
inRange (Just x) (Just (lo, hi)) _ = max lo (min hi x)
inRange (Just x) Nothing _ = x
inRange Nothing _ fallback = fallback

nearestRes :: (Int, Int) -> [(Int, Int)] -> (Int, Int)
nearestRes (w, h) = foldr1 closer
  where
    closer a b = if dist a <= dist b then a else b
    dist (w', h') = abs (w' - w) + abs (h' - h)
