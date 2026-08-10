{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | ffprobe integration: spawn ffprobe against an RTSP URL, parse the JSON
-- output, and extract the stream info we need to populate camera rows.
--
-- Used by 'Web.Controller.Cameras.ProbeCameraAction'.
module Web.Controller.Cameras.Probe
  ( ProbeInfo (..),
    probe,
  )
where

import Control.Exception (SomeException, try)
import Data.Aeson (FromJSON (..), Value (..), decode, (.:))
import qualified Data.Aeson.Key as K (fromText)
import Data.Aeson.Types (parseMaybe)
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Read as TR
import GHC.Generics (Generic)
import Generated.Enums (CodecKind (..))
import System.Exit (ExitCode (..))
import System.Process.Typed (byteStringOutput, proc, readProcessStdout, setStdout)

-- | Result of a successful ffprobe of an RTSP URL.
data ProbeInfo = ProbeInfo
  { probeCodec :: !CodecKind,
    probeWidth :: !Int,
    probeHeight :: !Int,
    probeFps :: !Double,
    probeAudio :: !(Maybe Text)
  }
  deriving stock (Eq, Show, Generic)

-- | Run ffprobe against the given RTSP URL over TCP. Returns the parsed
-- stream info or an error string.
--
-- We shell to ffprobe rather than parsing RTSP ourselves because the
-- camera vendors vary wildly in their SDP/DESCRIBE quirks (cam-196 needs
-- UDP, cam-198 ignores unknown paths, etc.) and ffprobe already handles
-- them. We don't pass the camera's transport preference here — TCP works
-- for all 3 of Sergey's cameras via the canonical URL form.
probe :: Text -> IO (Either Text ProbeInfo)
probe url = do
  let cfg =
        setStdout byteStringOutput $
          proc
            "ffprobe"
            [ "-v",
              "error",
              "-rtsp_transport",
              "tcp",
              "-timeout",
              "5000000",
              "-i",
              T.unpack url,
              "-show_streams",
              "-select_streams",
              "v:0",
              "-of",
              "json"
            ]
  result <- try (readProcessStdout cfg) :: IO (Either SomeException (ExitCode, BL.ByteString))
  case result of
    Left err -> pure (Left ("ffprobe invocation failed: " <> T.pack (show err)))
    Right (ExitFailure code, _) -> pure (Left ("ffprobe exited with code " <> T.pack (show code)))
    Right (ExitSuccess, bytes) ->
      case parseProbeInfo bytes of
        Nothing -> pure (Left "could not parse ffprobe JSON output")
        Just info -> pure (Right info)

parseProbeInfo :: BL.ByteString -> Maybe ProbeInfo
parseProbeInfo bytes = do
  value <- decode bytes
  streams <- case value of
    Object o -> parseMaybe (.: "streams") o
    _ -> Nothing
  firstStream <- firstStreamOf streams
  codecName <- codecField firstStream "codec_name"
  width <- codecField firstStream "width"
  height <- codecField firstStream "height"
  fpsStr <- codecField firstStream "r_frame_rate"
  let codec = case (codecName :: Text) of
        "h264" -> H264
        "hevc" -> Hevc
        _ -> Unknown
  pure
    ProbeInfo
      { probeCodec = codec,
        probeWidth = width,
        probeHeight = height,
        probeFps = parseFps fpsStr,
        probeAudio = Nothing
      }
  where
    firstStreamOf [] = Nothing
    firstStreamOf (v : _) = Just v
    codecField :: forall a. (FromJSON a) => Value -> Text -> Maybe a
    codecField (Object o) field = parseMaybe (.: K.fromText field) o
    codecField _ _ = Nothing
    parseFps :: Text -> Double
    parseFps s =
      case T.splitOn "/" s of
        [numStr, denStr] ->
          case (TR.decimal numStr, TR.decimal denStr) of
            (Right (num, _), Right (den, _)) | den /= 0 -> fromIntegral (num :: Int) / fromIntegral (den :: Int)
            _ -> 0
        _ -> 0
