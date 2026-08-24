{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Capture.Ffmpeg".
--
-- Pins the @recordingArgs@ argv for both transports — a golden test
-- that fails if anyone accidentally drops a flag. ffmpeg flag drift is
-- high-impact: the wrong @movflags@ value silently breaks fMP4
-- fragment boundaries.
module Hnvr.Capture.FfmpegSpec (tests) where

import Data.List (elemIndex)
import Data.Text (Text)
import qualified Data.Text as T
import Hnvr.Capture.Ffmpeg
  ( RecordingConfig (..),
    Transport (..),
    recordingArgs,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Capture.Ffmpeg"
    [ testCase "recordingArgs for TCP transport" $
        assertEqual
          "tcp argv"
          expectedTcp
          (recordingArgs tcpCfg),
      testCase "recordingArgs for UDP transport" $
        assertEqual
          "udp argv"
          expectedUdp
          (recordingArgs udpCfg),
      testCase "rtsp URL appears verbatim in argv" $ do
        let args = recordingArgs tcpCfg
        case dropWhile (/= "-i") args of
          _flag : url : _rest -> assertEqual "url" rtspUrlStr url
          _ -> fail "expected -i <url> in argv",
      testCase "recordAudio=True swaps -an for the filtered AAC chain" $ do
        let args = recordingArgs tcpCfg {rcRecordAudio = True}
        assertEqual "no -an" Nothing (elemIndex "-an" args)
        assertEqual
          "audio args"
          (Just audioArgsExpected)
          ( case dropWhile (/= "-af") args of
              [] -> Nothing
              xs -> Just (take 6 xs)
          ),
      testCase "16 kHz G.711 camera gets an asetrate retag before aresample" $ do
        let args = recordingArgs tcpCfg {rcRecordAudio = True, rcAudioInputRateHz = Just 16000}
        case dropWhile (/= "-af") args of
          _flag : chain : _ ->
            assertEqual
              "filter chain"
              "asetrate=16000,aresample=48000,highpass=f=60,highpass=f=60,lowpass=f=14000,lowpass=f=14000"
              chain
          _ -> fail "expected -af <chain> in argv",
      testCase "8 kHz / unset input rate adds no asetrate" $ do
        let chainOf c = case dropWhile (/= "-af") (recordingArgs c {rcRecordAudio = True}) of
              _flag : chain : _ -> chain
              _ -> ""
        assertEqual "8 kHz" "aresample=48000,highpass=f=60,highpass=f=60,lowpass=f=14000,lowpass=f=14000" (chainOf tcpCfg {rcAudioInputRateHz = Just 8000})
        assertEqual "unset" "aresample=48000,highpass=f=60,highpass=f=60,lowpass=f=14000,lowpass=f=14000" (chainOf tcpCfg)
    ]

-- | The exact audio argv slice (from @-af@ through the bitrate) that
-- must appear when @rcRecordAudio@ is set. Band-pass order is
-- load-bearing: aresample to 48 kHz BEFORE the high/lowpass (the G.711
-- input is 8 kHz — a 14 kHz lowpass at that rate is above Nyquist and
-- would compute garbage biquad coefficients).
audioArgsExpected :: [String]
audioArgsExpected =
  [ "-af",
    "aresample=48000,highpass=f=60,highpass=f=60,lowpass=f=14000,lowpass=f=14000",
    "-c:a",
    "aac",
    "-b:a",
    "64k"
  ]

-- ---- fixtures ------------------------------------------------------

rtspUrl :: Text
rtspUrl = "rtsp://admin:123456@192.168.0.197:554/stream"

rtspUrlStr :: String
rtspUrlStr = T.unpack rtspUrl

tcpCfg :: RecordingConfig
tcpCfg = RecordingConfig {rcUrl = rtspUrl, rcTransport = TcpTransport, rcRecordAudio = False, rcAudioInputRateHz = Nothing}

udpCfg :: RecordingConfig
udpCfg = RecordingConfig {rcUrl = rtspUrl, rcTransport = UdpTransport, rcRecordAudio = False, rcAudioInputRateHz = Nothing}

-- The flags documented in design_docs/03-capture-and-storage.md plus
-- the Sergey-camera-noise suppressors added Aug 11 2026
-- (@-loglevel error@, @-fflags +genpts+igndts+discardcorrupt@).
expectedTcp :: [String]
expectedTcp =
  [ "-hide_banner",
    "-loglevel",
    "error",
    "-fflags",
    "+genpts+igndts+discardcorrupt",
    "-rtsp_transport",
    "tcp",
    "-timeout",
    "5000000",
    "-i",
    rtspUrlStr,
    "-user_agent",
    "HNVR/0.1",
    "-reconnect",
    "1",
    "-reconnect_streamed",
    "1",
    "-reconnect_delay_max",
    "5",
    "-an",
    "-c:v",
    "copy",
    "-f",
    "mp4",
    "-movflags",
    "+frag_keyframe+empty_moov+default_base_moof+omit_tfhd_offset+faststart",
    "-frag_duration",
    "1000000",
    "-reset_timestamps",
    "1",
    "pipe:1"
  ]

expectedUdp :: [String]
expectedUdp = replaceAt expectedTcp (elemIndex "-rtsp_transport" expectedTcp) "udp"
  where
    -- Replace the value just after @-rtsp_transport@ with @udp@.
    replaceAt xs Nothing _ = xs
    replaceAt xs (Just i) v =
      let (before, _flag : _old : rest) = splitAt i xs
       in before <> ["-rtsp_transport", v] <> rest
