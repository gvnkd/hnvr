{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | ffmpeg subprocess construction for the capture pipelines.
--
-- Three invocations per camera exist in the full design (record +
-- analyze + optional audio); this module builds the argv lists for
-- all three.
--
-- The recording ffmpeg performs @-c:v copy@ (zero decode, zero encode)
-- and emits HLS-ready fMP4 fragments on stdout. We read those bytes,
-- slice them at @moof@\/@mdat@ boundaries via "Hnvr.Capture.Fmp4",
-- and upload each fragment to SeaweedFS. The analysis ffmpeg decodes
-- to RGB24 for the CV pipeline; "Hnvr.Capture.FrameSource" slices its
-- stdout into frames.
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
    audioArgs,
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
    rcTransport :: !Transport
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

-- | Build the recording ffmpeg process spec via @typed-process@. Stdin and
-- stderr are inherited; stdout is left as 'Inherited' so the caller can
-- redirect or pipe it (typically @setStdout createSource@).
recordingProc :: RecordingConfig -> ProcessConfig () () ()
recordingProc cfg = proc "ffmpeg" (recordingArgs cfg)

-- | Raw argv list for the audio recording ffmpeg. Same source URL and
-- transport as the video ffmpeg; the difference is @-vn -c:a copy@
-- (drop video, copy audio codec verbatim — zero CPU). Output is fMP4
-- fragments muxed as .m4a (MPEG-4 audio-only).
--
-- Per @03-capture-and-storage.md@ §3 this is the third optional ffmpeg
-- spawned when the camera's @record_audio@ flag is true. It runs in
-- parallel with the video ffmpeg in 'Hnvr.Capture.Worker.runOnce'
-- (each owns its own RTSP session through mediamtx's relay, so the
-- 1-session camera limit doesn't apply — both ffmpegs connect to
-- rtsp://localhost:8554/<slug>, mediamtx holds the single camera pull).
audioArgs :: RecordingConfig -> [String]
audioArgs cfg =
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
    "5",
    "-vn",
    "-c:a",
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
