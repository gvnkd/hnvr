{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | ffmpeg subprocess construction for the capture pipelines.
--
-- Two invocations per camera exist in the full design (record +
-- analyze); this module builds the argv lists for both.
--
-- The recording ffmpeg performs @-c:v copy@ (zero video decode, zero
-- video encode) and emits HLS-ready fMP4 fragments on stdout. When the
-- camera's @record_audio@ flag is set, the SAME ffmpeg also decodes the
-- camera's G.711 track, band-passes it (60 Hz – 14 kHz), re-encodes to
-- AAC, and muxes it into the same fragments — so archive playback gets
-- audio through the existing single-rendition HLS playlist with no
-- @EXT-X-MEDIA@ machinery. We read those bytes, slice them at
-- @moof@\/@mdat@ boundaries via "Hnvr.Capture.Fmp4", and upload each
-- fragment to SeaweedFS. The analysis ffmpeg decodes to RGB24 for the
-- CV pipeline; "Hnvr.Capture.FrameSource" slices its stdout into frames.
--
-- All flags are documented in @design_docs/03-capture-and-storage.md@
-- (\"Per-camera capture pipeline\"). The flag set MUST stay in sync
-- with that document — the fMP4 fragmenter and the HLS player both
-- depend on the exact @movflags@ we use here.
module Hnvr.Capture.Ffmpeg
  ( -- * Configuration
    Transport (..),
    RecordingConfig (..),
    AnalysisConfig (..),

    -- * Args
    recordingArgs,
    analysisArgs,

    -- * Process (typed-process)
    recordingProc,
  )
where

import Data.Text (Text)
import qualified Data.Text as T
import System.Process.Typed (ProcessConfig, proc)

-- | RTSP transport selection. Most cameras work over TCP interleaved
-- (no UDP packet loss on LAN). Camera 196 in Sergey's test set requires
-- UDP — TCP setup is rejected with @Connection reset by peer@.
data Transport = TcpTransport | UdpTransport
  deriving stock (Eq, Show)

-- | Configuration for the recording ffmpeg.
data RecordingConfig = RecordingConfig
  { -- | Full RTSP URL with embedded credentials.
    rcUrl :: !Text,
    -- | Transport. Mismatched transport fails fast at RTSP SETUP.
    rcTransport :: !Transport,
    -- | When True, the camera's audio track is decoded, band-passed
    -- (60 Hz – 14 kHz), re-encoded to AAC and muxed into the same fMP4
    -- fragments as the video. When False the audio track is dropped
    -- (@-an@). Cameras without an audio track produce video-only
    -- fragments either way (default stream mapping finds no audio).
    rcRecordAudio :: !Bool,
    -- | Camera's real audio sampling rate (Hz) when it runs a fixed
    -- 8 kHz RTP clock at a higher true rate (G.711/G.726 — RFC 3551
    -- fixes the PCMU\/PCMA clock at 8000 whatever the camera samples
    -- at; Sergey's Hik-OEMs send 16000 samples\/s that ffmpeg then
    -- decodes as 2×-slowed 8 kHz audio). When set (and ≠ 8 kHz), the
    -- decoded stream is retagged with @asetrate@ BEFORE resampling so
    -- pitch and speed come out right. 'Nothing' = trust the SDP clock.
    rcAudioInputRateHz :: !(Maybe Int)
  }
  deriving stock (Eq, Show)

transportArg :: Transport -> String
transportArg TcpTransport = "tcp"
transportArg UdpTransport = "udp"

-- | Raw argv list for the recording ffmpeg. Use this if you want to spawn
-- the process via "System.Process" or your own runtime; prefer
-- 'recordingProc' for typed-process callers.
--
-- Flags tuned for Sergey's consumer-grade RTSP cameras (XM / Hikvision
-- OEM / icamra firmware — see "Sergey's cameras" in MEMORIES.md):
--
--   * @-loglevel error@ — silence the noisy non-fatal warnings
--     (@Timestamps are unset in a packet@, @Non-monotonic DTS@,
--     @Failed reading RTSP data: Connection timed out@) that the
--     cameras produce constantly. Real failures still appear, and
--     our own 'CaptureWorker' logs every ffmpeg exit + backoff cycle
--     through the locked 'Hnvr.Core.Logging.logInfo' so visibility is
--     preserved at the supervisor level.
--   * @-fflags +genpts+igndts+discardcorrupt@ — fix the timestamp /
--     DTS warnings at the source rather than just hiding them:
--     @genpts@ regenerates missing PTS, @igndts@ ignores the
--     non-monotonic DTS, @discardcorrupt@ drops malformed packets
--     instead of complaining.
recordingArgs :: RecordingConfig -> [String]
recordingArgs cfg =
  [ "-hide_banner",
    "-loglevel",
    "error",
    "-fflags",
    "+genpts+igndts+discardcorrupt",
    "-rtsp_transport",
    transportArg (rcTransport cfg),
    "-timeout",
    "5000000",
    "-i",
    T.unpack (rcUrl cfg),
    "-user_agent",
    "HNVR/0.1",
    "-reconnect",
    "1",
    "-reconnect_streamed",
    "1",
    "-reconnect_delay_max",
    "5"
  ]
    <> audioOpts
    <> [ "-c:v",
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
  where
    -- Audio band-pass: resample to 48 kHz FIRST (the cameras send
    -- G.711 at 8 kHz — a 14 kHz lowpass at 8 kHz Nyquist would produce
    -- garbage biquad coefficients), then a cascaded (4th-order) 60 Hz
    -- highpass + 14 kHz lowpass, then AAC. Filter order matters:
    -- aresample must precede highpass/lowpass. Measured: -24 dB @
    -- 30 Hz, -52 dB @ 20 kHz, 0 dB @ 1 kHz.
    --
    -- When the camera runs a fixed 8 kHz RTP clock at a higher real
    -- sampling rate ('rcAudioInputRateHz'), an @asetrate@ retag comes
    -- first of all: it re-labels the decoded frames at the true rate
    -- (no resample, pitch+speed corrected) before aresample does the
    -- rate conversion.
    --
    -- @asetpts=NB_CONSUMED_SAMPLES\/SR\/TB@ rebuilds the audio PTS from
    -- the cumulative sample count after aresample. The Hik-OEMs emit
    -- audio RTP whose DTS jumps backward ~112 ms every couple of
    -- seconds; ffmpeg clamps each jump to prev+1, and the fMP4 muxer
    -- then writes trun sample durations of ~22 ticks instead of 1024 —
    -- media time collapses to ~2% of wall time in stretches, the
    -- archive player's A/V-slope probe reads those windows as
    -- legacy-skewed and strips the (fully present) audio. Regenerated
    -- from sample counts, encoder input is perfectly monotonic and
    -- every AAC frame lands with duration 1024 (muxer even coalesces
    -- to tfhd default_sample_duration).
    audioOpts
      | rcRecordAudio cfg =
          [ "-af",
            asetrate <> "aresample=48000,asetpts=NB_CONSUMED_SAMPLES/SR/TB,highpass=f=60,highpass=f=60,lowpass=f=14000,lowpass=f=14000",
            "-c:a",
            "aac",
            "-b:a",
            "64k"
          ]
      | otherwise = ["-an"]
    asetrate = case rcAudioInputRateHz cfg of
      Just r | r > 0 && r /= 8000 -> "asetrate=" <> show r <> ","
      _ -> ""

-- | Build the recording ffmpeg process spec via @typed-process@. Stdin and
-- stderr are inherited; stdout is left as 'Inherited' so the caller can
-- redirect or pipe it (typically @setStdout createSource@).
recordingProc :: RecordingConfig -> ProcessConfig () () ()
recordingProc cfg = proc "ffmpeg" (recordingArgs cfg)

-- | Configuration for the analysis ffmpeg (Phase 3 CV pipeline).
--
-- Two shapes per @03-capture-and-storage.md@ §2b:
--
--   * sub-stream decode (default) — direct camera sub-stream URL, no
--     scale filter; the sub-stream is already small (704×576 / 720×480
--     on Sergey's set).
--   * main-stream-with-scale fallback (@use_substream_for_analysis =
--     false@ or dims unknown) — mediamtx relay URL + @scale=640:360@.
data AnalysisConfig = AnalysisConfig
  { -- | RTSP URL — camera sub-stream direct, or mediamtx relay.
    ancUrl :: !Text,
    -- | Transport. TCP for both shapes (relay is localhost; camera
    -- sub-stream follows the camera's working transport).
    ancTransport :: !Transport,
    -- | @Just (640, 360)@ on the fallback path, 'Nothing' for native
    -- sub-stream decode.
    ancScale :: !(Maybe (Int, Int)),
    -- | Decode rate cap (@cameras.analysis_fps@, default 5).
    ancFps :: !Int
  }
  deriving stock (Eq, Show)

-- | Raw argv list for the analysis ffmpeg. Decodes to tightly-packed
-- RGB24 on stdout; 'Hnvr.Capture.FrameSource' slices the byte stream
-- into 'Hnvr.Core.Frame' records of @width*height*3@ bytes each.
analysisArgs :: AnalysisConfig -> [String]
analysisArgs cfg =
  [ "-hide_banner",
    "-loglevel",
    "error",
    "-fflags",
    "+genpts+igndts+discardcorrupt",
    "-rtsp_transport",
    transportArg (ancTransport cfg),
    "-timeout",
    "5000000",
    "-i",
    T.unpack (ancUrl cfg),
    "-user_agent",
    "HNVR/0.1",
    "-reconnect",
    "1",
    "-reconnect_streamed",
    "1",
    "-reconnect_delay_max",
    "5",
    "-an",
    "-sn",
    "-dn",
    "-vf",
    vfChain,
    "-f",
    "rawvideo",
    "-pix_fmt",
    "rgb24",
    "pipe:1"
  ]
  where
    vfChain =
      T.unpack $
        T.intercalate "," $
          ["fps=" <> T.pack (show (ancFps cfg))]
            <> maybe [] (\(w, h) -> ["scale=" <> T.pack (show w) <> ":" <> T.pack (show h)]) (ancScale cfg)
