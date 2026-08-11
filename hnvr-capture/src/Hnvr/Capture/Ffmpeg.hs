{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | ffmpeg subprocess construction for the recording pipeline.
--
-- Two invocations per camera exist in the full design (record + analyze);
-- this module covers the /recording/ ffmpeg only — the analysis ffmpeg
-- lands with the CV pipeline in Phase 3.
--
-- The recording ffmpeg performs @-c:v copy@ (zero decode, zero encode) and
-- emits HLS-ready fMP4 fragments on stdout. We read those bytes, slice them
-- at @moof@\/@mdat@ boundaries via "Hnvr.Capture.Fmp4", and upload each
-- fragment to SeaweedFS.
--
-- All flags are documented in @design_docs/03-capture-and-storage.md@
-- (\"Per-camera capture pipeline\"). The flag set MUST stay in sync with
-- that document — the fMP4 fragmenter and the HLS player both depend on
-- the exact @movflags@ we use here.
module Hnvr.Capture.Ffmpeg
  ( -- * Configuration
    Transport (..),
    RecordingConfig (..),

    -- * Args
    recordingArgs,

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
  where
    transportArg TcpTransport = "tcp"
    transportArg UdpTransport = "udp"

-- | Build the recording ffmpeg process spec via @typed-process@. Stdin and
-- stderr are inherited; stdout is left as 'Inherited' so the caller can
-- redirect or pipe it (typically @setStdout createSource@).
recordingProc :: RecordingConfig -> ProcessConfig () () ()
recordingProc cfg = proc "ffmpeg" (recordingArgs cfg)
