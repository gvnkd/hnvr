-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}

module Generated.Statements.CreateCamera (statement, discardResultStatement) where

import qualified Data.Aeson
import Data.Bits (testBit)
import Data.Default (def)
import qualified Data.Dynamic
import Data.Functor.Contravariant (contramap, (>$<))
import Data.Int (Int16, Int32, Int64)
import Data.Maybe (catMaybes)
import Data.Scientific (Scientific)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Time.Calendar
import Data.Time.Clock (UTCTime)
import Data.Time.LocalTime (LocalTime, TimeOfDay)
import Data.UUID (UUID)
import qualified Database.PostgreSQL.Simple.Types
import Generated.ActualTypes
import Generated.Enums
import qualified Generated.Statements.RowDecoderCamera as RowDecoder
import qualified Hasql.Decoders as Decoders
import qualified Hasql.Encoders as Encoders
import qualified Hasql.Mapping.IsScalar as Mapping
import Hasql.PostgresqlTypes ()
import qualified Hasql.Statement as Statement
import IHP.Job.Queue ()
import IHP.ModelSupport.Types (Id' (..), MetaBag (..))
import PostgresqlTypes.Inet (Inet)
import PostgresqlTypes.Interval (Interval)
import PostgresqlTypes.Point (Point)
import PostgresqlTypes.Polygon (Polygon)
import PostgresqlTypes.Tsvector (Tsvector)
import Prelude (Bool (..), Int, Integer, Maybe (..), fromIntegral, length, map, mconcat, not, null, pure, show, zip, (!!), ($), (&&), (*), (+), (++), (-), (.), (<$>), (<*>), (<>))

statement :: Integer -> Statement.Statement Generated.ActualTypes.Camera Generated.ActualTypes.Camera
statement touchedFields = Statement.preparable (sql touchedFields True) (encoder touchedFields) decoder

discardResultStatement :: Integer -> Statement.Statement Generated.ActualTypes.Camera ()
discardResultStatement touchedFields = Statement.preparable (sql touchedFields False) (encoder touchedFields) Decoders.noResult

sql :: Integer -> Bool -> Text
sql touchedFields returning =
  let entries =
        catMaybes
          [ if testBit touchedFields 0 then Just "id" else Nothing,
            Just "slug",
            Just "name",
            Just "rtsp_url",
            if testBit touchedFields 4 then Just "rtsp_transport" else Nothing,
            Just "host",
            Just "username",
            Just "password_enc",
            Just "password_nonce",
            if testBit touchedFields 9 then Just "codec" else Nothing,
            Just "rtsp_sub_url",
            if testBit touchedFields 11 then Just "use_substream_for_analysis" else Nothing,
            if testBit touchedFields 12 then Just "substream_codec" else Nothing,
            Just "substream_width",
            Just "substream_height",
            if testBit touchedFields 15 then Just "record_audio" else Nothing,
            if testBit touchedFields 16 then Just "analysis_fps" else Nothing,
            if testBit touchedFields 17 then Just "model_name" else Nothing,
            if testBit touchedFields 18 then Just "enabled" else Nothing,
            if testBit touchedFields 19 then Just "retention_hours" else Nothing,
            Just "assigned_host",
            if testBit touchedFields 21 then Just "manual_assign" else Nothing,
            Just "onvif_port",
            if testBit touchedFields 23 then Just "mgmt_proto" else Nothing,
            Just "main_video_encoding",
            Just "main_video_width",
            Just "main_video_height",
            Just "main_video_fps",
            Just "main_video_bitrate_kbps",
            Just "main_video_gov_length",
            Just "sub_video_encoding",
            Just "sub_video_width",
            Just "sub_video_height",
            Just "sub_video_fps",
            Just "sub_video_bitrate_kbps",
            Just "sub_video_gov_length",
            Just "audio_encoding",
            Just "audio_bitrate_kbps",
            Just "audio_sample_rate_khz",
            if testBit touchedFields 39 then Just "created_at" else Nothing,
            if testBit touchedFields 40 then Just "updated_at" else Nothing
          ]
      columns = Text.intercalate ", " entries
      placeholders = Text.intercalate ", " ["$" <> Text.pack (show i) | i <- [1 .. length entries]]
      returningClause = if returning then " RETURNING id, slug, name, rtsp_url, rtsp_transport, host, username, password_enc, password_nonce, codec, rtsp_sub_url, use_substream_for_analysis, substream_codec, substream_width, substream_height, record_audio, analysis_fps, model_name, enabled, retention_hours, assigned_host, manual_assign, onvif_port, mgmt_proto, main_video_encoding, main_video_width, main_video_height, main_video_fps, main_video_bitrate_kbps, main_video_gov_length, sub_video_encoding, sub_video_width, sub_video_height, sub_video_fps, sub_video_bitrate_kbps, sub_video_gov_length, audio_encoding, audio_bitrate_kbps, audio_sample_rate_khz, created_at, updated_at" else ""
   in if null entries
        then "INSERT INTO cameras DEFAULT VALUES" <> returningClause
        else "INSERT INTO cameras (" <> columns <> ") VALUES (" <> placeholders <> ")" <> returningClause

encoder :: Integer -> Encoders.Params Generated.ActualTypes.Camera
encoder touchedFields =
  mconcat $
    catMaybes
      [ if testBit touchedFields 0 then Just ((.id) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing,
        Just ((.slug) >$< Encoders.param (Encoders.nonNullable Encoders.text)),
        Just ((.name) >$< Encoders.param (Encoders.nonNullable Encoders.text)),
        Just ((.rtspUrl) >$< Encoders.param (Encoders.nonNullable Encoders.text)),
        if testBit touchedFields 4 then Just ((.rtspTransport) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing,
        Just ((.host) >$< Encoders.param (Encoders.nullable Encoders.text)),
        Just ((.username) >$< Encoders.param (Encoders.nullable Encoders.text)),
        Just ((.passwordEnc) >$< Encoders.param (Encoders.nullable ((\(Database.PostgreSQL.Simple.Types.Binary bs) -> bs) >$< Encoders.bytea))),
        Just ((.passwordNonce) >$< Encoders.param (Encoders.nullable ((\(Database.PostgreSQL.Simple.Types.Binary bs) -> bs) >$< Encoders.bytea))),
        if testBit touchedFields 9 then Just ((.codec) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing,
        Just ((.rtspSubUrl) >$< Encoders.param (Encoders.nullable Encoders.text)),
        if testBit touchedFields 11 then Just ((.useSubstreamForAnalysis) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing,
        if testBit touchedFields 12 then Just ((.substreamCodec) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing,
        Just ((.substreamWidth) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))),
        Just ((.substreamHeight) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))),
        if testBit touchedFields 15 then Just ((.recordAudio) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing,
        if testBit touchedFields 16 then Just ((.analysisFps) >$< Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int4))) else Nothing,
        if testBit touchedFields 17 then Just ((.modelName) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing,
        if testBit touchedFields 18 then Just ((.enabled) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing,
        if testBit touchedFields 19 then Just ((.retentionHours) >$< Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int4))) else Nothing,
        Just ((.assignedHost) >$< Encoders.param (Encoders.nullable Encoders.text)),
        if testBit touchedFields 21 then Just ((.manualAssign) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing,
        Just ((.onvifPort) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))),
        if testBit touchedFields 23 then Just ((.mgmtProto) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing,
        Just ((.mainVideoEncoding) >$< Encoders.param (Encoders.nullable Encoders.text)),
        Just ((.mainVideoWidth) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))),
        Just ((.mainVideoHeight) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))),
        Just ((.mainVideoFps) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))),
        Just ((.mainVideoBitrateKbps) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))),
        Just ((.mainVideoGovLength) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))),
        Just ((.subVideoEncoding) >$< Encoders.param (Encoders.nullable Encoders.text)),
        Just ((.subVideoWidth) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))),
        Just ((.subVideoHeight) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))),
        Just ((.subVideoFps) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))),
        Just ((.subVideoBitrateKbps) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))),
        Just ((.subVideoGovLength) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))),
        Just ((.audioEncoding) >$< Encoders.param (Encoders.nullable Encoders.text)),
        Just ((.audioBitrateKbps) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))),
        Just ((.audioSampleRateKhz) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))),
        if testBit touchedFields 39 then Just ((.createdAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing,
        if testBit touchedFields 40 then Just ((.updatedAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
      ]

decoder :: Decoders.Result Generated.ActualTypes.Camera
decoder = Decoders.singleRow RowDecoder.rowDecoder
