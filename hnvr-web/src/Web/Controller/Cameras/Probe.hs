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
--
-- Probes video (v:0) and audio (a:0) in two separate calls so the JSON
-- shape stays predictable per call. Sergey's cameras all carry G.711
-- audio (pcm_alaw / pcm_mulaw) per the fixtures table in MEMORIES.md —
-- @probeAudio@ returns that codec name when present, 'Nothing' when
-- the camera has no audio track.
probe :: Text -> IO (Either Text ProbeInfo)
probe url = do
  videoResult <- probeStream url "v:0"
  case videoResult of
    Left err -> pure (Left err)
    Right (codecName, width, height, fps) -> do
      audioResult <- probeStream url "a:0"
      let audioCodec = case audioResult of
            Right (codecNameA, _, _, _) -> Just codecNameA
            Left _ -> Nothing
          codec = case codecName of
            "h264" -> H264
            "hevc" -> Hevc
            _ -> Unknown
      pure
        ( Right
            ProbeInfo
              { probeCodec = codec,
                probeWidth = width,
                probeHeight = height,
                probeFps = fps,
                probeAudio = audioCodec
              }
        )

-- | One-stream ffprobe. Returns (codec_name_text, width, height, fps).
-- For audio streams width/height/fps are 0 (the values aren't meaningful
-- but we keep the tuple shape uniform so the caller doesn't need a
-- separate audio-specific parser).
probeStream :: Text -> Text -> IO (Either Text (Text, Int, Int, Double))
probeStream url streamSel = do
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
              T.unpack streamSel,
              "-of",
              "json"
            ]
  result <- try (readProcessStdout cfg) :: IO (Either SomeException (ExitCode, BL.ByteString))
  case result of
    Left err -> pure (Left ("ffprobe invocation failed: " <> T.pack (show err)))
    Right (ExitFailure code, _) -> pure (Left ("ffprobe exited with code " <> T.pack (show code)))
    Right (ExitSuccess, bytes) ->
      case parseStreamInfo bytes of
        Nothing -> pure (Left "could not parse ffprobe JSON output")
        Just info -> pure (Right info)

parseStreamInfo :: BL.ByteString -> Maybe (Text, Int, Int, Double)
parseStreamInfo bytes = do
  value <- decode bytes
  streams <- case value of
    Object o -> parseMaybe (.: "streams") o
    _ -> Nothing
  firstStream <- firstStreamOf streams
  codecName <- codecField firstStream "codec_name"
  let width = fromMaybe 0 (codecField firstStream "width")
      height = fromMaybe 0 (codecField firstStream "height")
      fpsStr = fromMaybe "0/1" (codecField firstStream "r_frame_rate")
  pure (codecName, width, height, parseFps fpsStr)
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

-- | Backwards-compat wrapper preserved for any caller that wants the
-- old shape. The new 'probe' returns 'ProbeInfo' directly so this is
-- just a thin shim around the new implementation.
parseProbeInfo :: BL.ByteString -> Maybe ProbeInfo
parseProbeInfo bytes = do
  (codecName, width, height, fps) <- parseStreamInfo bytes
  let codec = case codecName of
        "h264" -> H264
        "hevc" -> Hevc
        _ -> Unknown
  pure
    ProbeInfo
      { probeCodec = codec,
        probeWidth = width,
        probeHeight = height,
        probeFps = fps,
        probeAudio = Nothing -- audio detected via the second probeStream call in 'probe'
      }
