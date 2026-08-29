{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Live-view (WHEP) path generation for MediaMTX.
--
-- The browser-facing WHEP stream cannot be the raw camera relay:
-- MediaMTX republishes tracks untouched, WebRTC plays PCMU strictly
-- at its declared 8 kHz clock, and AAC is not a WebRTC codec at all.
-- Cameras with the fixed-clock G.711 quirk (16 kHz samples under an
-- 8 kHz clock — see "Hnvr.Core.AudioProbe") therefore arrive 2x
-- slowed in every live view, and AAC cameras arrive silent.
--
-- The fix: a second MediaMTX path per camera, @<slug>-live@, whose
-- @runOnDemand@ command pulls the ingestion relay, copies video, and
-- re-encodes audio to Opus with the @asetrate@ retag baked in. The
-- command only runs while a WHEP viewer watches (MediaMTX starts it
-- on first reader and kills it when the last reader leaves), and
-- pulling the LOCAL relay keeps the single-ingestion invariant
-- (one RTSP session per camera regardless of viewers).
module Hnvr.Core.MediaMtxLive
  ( -- * Path naming
    livePathSuffix,
    livePathName,

    -- * Per-camera live audio policy
    AudioPresence (..),
    LiveAudio (..),
    runOnDemandCmd,

    -- * Config rendering
    CameraPath (..),
    livePathConfig,
    renderPathsYaml,
    pathConfigs,
  )
where

import Data.Aeson (Value, object, (.=))
import Data.Text (Text)
import qualified Data.Text as T

-- | Suffix distinguishing the transcoded live path from the ingestion
-- path. Also stripped by @Hnvr.Core.Whep.translateBack@ when
-- rewriting MediaMTX Location headers.
livePathSuffix :: Text
livePathSuffix = "-live"

-- | @backyard@ → @backyard-live@.
livePathName :: Text -> Text
livePathName slug = slug <> livePathSuffix

-- | What we know about the camera's audio track.
data AudioPresence = AudioYes | AudioNo | AudioUnknown
  deriving stock (Eq, Show)

-- | Audio policy for one camera's live path.
data LiveAudio = LiveAudio
  { -- | @asetrate@ Hz for the fixed-clock quirk ('Nothing' = trust
    -- the SDP clock; never applied to non-G.711-family codecs).
    laAsetrateHz :: !(Maybe Int),
    -- | Whether the camera has an audio track at all. 'AudioUnknown'
    -- (DB has no audio columns) emits an optional audio map that is
    -- a no-op when the track is absent.
    laPresence :: !AudioPresence
  }
  deriving stock (Eq, Show)

-- | One camera's MediaMTX footprint: the ingestion path (raw relay
-- the CaptureWorker and the live republisher pull from) and the
-- @-live@ transcoded path browsers watch.
data CameraPath = CameraPath
  { cpSlug :: !Text,
    cpSource :: !Text,
    cpTransport :: !Text,
    cpEnabled :: !Bool,
    cpLiveAudio :: !LiveAudio
  }
  deriving stock (Eq, Show)

-- | The @runOnDemand@ command for @<slug>-live@. Single line (YAML
-- plain value; quoted at render time), no shell features. Video is
-- copied untouched; audio is re-encoded to Opus (the only audio
-- family every WebRTC stack decodes) with the quirk retag first when
-- known:
--
--   * known quirk rate → @-af asetrate=<r>,aresample=48000@;
--   * audio, honest clock → @-ar 48000@ (covers AAC transparently);
--   * unknown audio → optional map @0:a:0?@ + @-ar 48000@, a no-op
--     when the track is absent;
--   * known audio-less → @-an@.
runOnDemandCmd :: Text -> Text -> LiveAudio -> Text
runOnDemandCmd relayBase slug (LiveAudio mrate presence) =
  T.intercalate
    " "
    ( [ "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-fflags",
        "+genpts+igndts+discardcorrupt",
        "-rtsp_transport",
        "tcp",
        "-timeout",
        "5000000",
        "-i",
        inUrl,
        "-map",
        "0:v:0"
      ]
        <> audioOpts
        <> [ "-rtsp_transport",
             "tcp",
             "-f",
             "rtsp",
             outUrl
           ]
    )
  where
    inUrl = relayBase <> "/" <> slug
    outUrl = relayBase <> "/" <> livePathName slug
    audioOpts = case (presence, mrate) of
      (AudioNo, _) -> ["-an", "-c:v", "copy"]
      (AudioYes, Just r) ->
        [ "-map",
          "0:a:0",
          "-c:v",
          "copy",
          "-af",
          "asetrate=" <> T.pack (show r) <> ",aresample=48000",
          "-c:a",
          "libopus",
          "-b:a",
          "64k"
        ]
      (AudioYes, Nothing) ->
        ["-map", "0:a:0", "-c:v", "copy", "-ar", "48000", "-c:a", "libopus", "-b:a", "64k"]
      (AudioUnknown, _) ->
        ["-map", "0:a:0?", "-c:v", "copy", "-ar", "48000", "-c:a", "libopus", "-b:a", "64k"]

-- | REST-API config body for the @<slug>-live@ path (v3 add\/patch).
livePathConfig :: Text -> Text -> LiveAudio -> Value
livePathConfig relayBase slug la =
  object
    [ "runOnDemand" .= runOnDemandCmd relayBase slug la,
      "runOnDemandRestart" .= True,
      "runOnDemandStartTimeout" .= ("20s" :: Text)
    ]

-- | Render the full @mediamtx.yml@ body for the given cameras. Same
-- header the leader has always written (ports match the NixOS module
-- defaults); each enabled camera contributes its ingestion path plus
-- the @-live@ transcoded path. The @runOnDemand@ value is
-- single-quoted so embedded colons can never terminate the scalar.
renderPathsYaml :: Text -> [CameraPath] -> Text
renderPathsYaml relayBase cams =
  T.unlines $
    [ "# Auto-generated by HNVR MediaMTXConfigSyncer. Do not edit.",
      "api: yes",
      "apiAddress: :9997",
      "hls: no",
      "moq: no",
      "webrtc: yes",
      "webrtcAddress: :8889",
      "webrtcLocalUDPAddress: :8189",
      "webrtcEncryption: no",
      "webrtcAllowOrigins: ['*']",
      -- RTSP *server* on :8554 — CaptureWorker pulls from
      -- rtsp://localhost:8554/<slug> instead of from the camera so
      -- mediamtx is the single ingestion point. Required for cameras
      -- with a 1-concurrent-RTSP-session cap.
      "rtsp: yes",
      "rtspAddress: :8554",
      "paths:"
    ]
      <> concatMap pathFor cams
  where
    pathFor cam
      | not (cpEnabled cam) = mempty
      | otherwise =
          [ "  " <> cpSlug cam <> ":",
            "    runOnDemand: '" <> execSourceCmd (cpSlug cam) (cpSource cam) (cpTransport cam) <> "'",
            "    runOnDemandRestart: yes",
            "    runOnDemandStartTimeout: 20s",
            "  " <> livePathName (cpSlug cam) <> ":",
            "    runOnDemand: '"
              <> runOnDemandCmd relayBase (cpSlug cam) (cpLiveAudio cam)
              <> "'",
            "    runOnDemandRestart: yes",
            "    runOnDemandStartTimeout: 20s"
          ]

-- | Ingestion via an ffmpeg republisher instead of a raw RTSP source.
--
-- ICAMRA-OEM cameras emit a malformed SDP after switching to AAC: the
-- m=audio line keeps static payload type 0 (PCMU) while the rtpmap
-- overrides it to MPEG4-GENERIC/16000. ffmpeg honors the rtpmap,
-- gortsplib (mediamtx) binds static PT 0 as G.711 — a plain rtsp://
-- source makes the relay re-label AAC payloads as PCMU, and every
-- downstream consumer hears noise. mediamtx has no exec: source, but
-- runOnDemand is the same mechanism: the command publishes to the
-- path (ffmpeg -c copy, no transcoding) with a correct dynamic-PT
-- announcement. The recorder ffmpegs are persistent readers, so the
-- command stays up; single-ingestion-point semantics unchanged.
execSourceCmd :: Text -> Text -> Text -> Text
execSourceCmd slug url transport =
  "ffmpeg -loglevel error -rtsp_transport "
    <> transport
    <> " -i "
    <> url
    <> " -c copy -rtsp_transport tcp -f rtsp rtsp://127.0.0.1:8554/"
    <> slug

-- | Per-path REST payloads for the enabled cameras: the ingestion
-- path (unchanged shape) plus the @-live@ transcoded path, as
-- @(pathName, config)@ pairs for the syncer's add\/patch\/delete
-- reconciliation.
--
-- The ingestion payload uses @rtspTransport@ — the field mediamtx
-- actually reads for RTSP sources (per internal\/api\/path.go in
-- v1.20.0). Its sibling @sourceProtocol@ only applies to non-RTSP
-- sources; setting the wrong one silently leaves RTSP on TCP, which
-- tears down cameras that reject TCP SETUP (Sergey's cam-196).
pathConfigs :: Text -> [CameraPath] -> [(Text, Value)]
pathConfigs relayBase cams =
  concatMap
    ( \cam ->
        [ ( cpSlug cam,
            object
              [ "runOnDemand" .= execSourceCmd (cpSlug cam) (cpSource cam) (cpTransport cam),
                "runOnDemandRestart" .= True,
                "runOnDemandStartTimeout" .= ("20s" :: Text)
              ]
          ),
          ( livePathName (cpSlug cam),
            livePathConfig relayBase (cpSlug cam) (cpLiveAudio cam)
          )
        ]
    )
    (filter cpEnabled cams)
