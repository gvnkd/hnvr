-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}
module Generated.Statements.UpdateCamera (statement, discardResultStatement) where

import Prelude (($), (.), (<$>), (<*>), (<>), (+), (*), (-), show, fromIntegral, length, null, zip, mconcat, (++), Maybe(..), (!!), map, Bool(..), Int, Integer, pure, (&&), not)
import Generated.ActualTypes
import Generated.Enums
import IHP.ModelSupport.Types (Id'(..), MetaBag(..))
import qualified Hasql.Statement as Statement
import qualified Hasql.Decoders as Decoders
import qualified Hasql.Encoders as Encoders
import qualified Hasql.Mapping.IsScalar as Mapping
import Hasql.PostgresqlTypes ()
import IHP.Job.Queue ()
import Data.Functor.Contravariant (contramap, (>$<))
import Data.Default (def)
import qualified Data.Dynamic
import Data.UUID (UUID)
import Data.Text (Text)
import Data.Int (Int16, Int32, Int64)
import Data.Time.Clock (UTCTime)
import Data.Time.LocalTime (LocalTime, TimeOfDay)
import qualified Data.Time.Calendar
import Data.Scientific (Scientific)
import qualified Data.Aeson
import qualified Database.PostgreSQL.Simple.Types
import PostgresqlTypes.Point (Point)
import PostgresqlTypes.Polygon (Polygon)
import PostgresqlTypes.Inet (Inet)
import PostgresqlTypes.Tsvector (Tsvector)
import PostgresqlTypes.Interval (Interval)

import qualified Generated.Statements.RowDecoderCamera as RowDecoder
import Data.Bits (testBit)
import Data.Maybe (catMaybes)
import qualified Data.Text as Text
statement :: Integer -> Statement.Statement Generated.ActualTypes.Camera Generated.ActualTypes.Camera
statement touchedFields = Statement.preparable (sql touchedFields True) (encoder touchedFields) decoder

discardResultStatement :: Integer -> Statement.Statement Generated.ActualTypes.Camera ()
discardResultStatement touchedFields = Statement.preparable (sql touchedFields False) (encoder touchedFields) Decoders.noResult

sql :: Integer -> Bool -> Text
sql touchedFields returning =
    let setEntries = catMaybes
            [ if testBit touchedFields 1 then Just "slug" else Nothing
            , if testBit touchedFields 2 then Just "name" else Nothing
            , if testBit touchedFields 3 then Just "rtsp_url" else Nothing
            , if testBit touchedFields 4 then Just "rtsp_template" else Nothing
            , if testBit touchedFields 5 then Just "rtsp_transport" else Nothing
            , if testBit touchedFields 6 then Just "host" else Nothing
            , if testBit touchedFields 7 then Just "port" else Nothing
            , if testBit touchedFields 8 then Just "username" else Nothing
            , if testBit touchedFields 9 then Just "password_enc" else Nothing
            , if testBit touchedFields 10 then Just "password_nonce" else Nothing
            , if testBit touchedFields 11 then Just "codec" else Nothing
            , if testBit touchedFields 12 then Just "rtsp_sub_url" else Nothing
            , if testBit touchedFields 13 then Just "rtsp_sub_template" else Nothing
            , if testBit touchedFields 14 then Just "use_substream_for_analysis" else Nothing
            , if testBit touchedFields 15 then Just "substream_codec" else Nothing
            , if testBit touchedFields 16 then Just "substream_width" else Nothing
            , if testBit touchedFields 17 then Just "substream_height" else Nothing
            , if testBit touchedFields 18 then Just "record_audio" else Nothing
            , if testBit touchedFields 19 then Just "analysis_fps" else Nothing
            , if testBit touchedFields 20 then Just "model_name" else Nothing
            , if testBit touchedFields 21 then Just "enabled" else Nothing
            , if testBit touchedFields 22 then Just "retention_hours" else Nothing
            , if testBit touchedFields 23 then Just "assigned_host" else Nothing
            , if testBit touchedFields 24 then Just "manual_assign" else Nothing
            , if testBit touchedFields 25 then Just "onvif_port" else Nothing
            , if testBit touchedFields 26 then Just "mgmt_proto" else Nothing
            , if testBit touchedFields 27 then Just "main_video_encoding" else Nothing
            , if testBit touchedFields 28 then Just "main_video_width" else Nothing
            , if testBit touchedFields 29 then Just "main_video_height" else Nothing
            , if testBit touchedFields 30 then Just "main_video_fps" else Nothing
            , if testBit touchedFields 31 then Just "main_video_bitrate_kbps" else Nothing
            , if testBit touchedFields 32 then Just "main_video_gov_length" else Nothing
            , if testBit touchedFields 33 then Just "sub_video_encoding" else Nothing
            , if testBit touchedFields 34 then Just "sub_video_width" else Nothing
            , if testBit touchedFields 35 then Just "sub_video_height" else Nothing
            , if testBit touchedFields 36 then Just "sub_video_fps" else Nothing
            , if testBit touchedFields 37 then Just "sub_video_bitrate_kbps" else Nothing
            , if testBit touchedFields 38 then Just "sub_video_gov_length" else Nothing
            , if testBit touchedFields 39 then Just "audio_encoding" else Nothing
            , if testBit touchedFields 40 then Just "audio_bitrate_kbps" else Nothing
            , if testBit touchedFields 41 then Just "audio_sample_rate_khz" else Nothing
            , if testBit touchedFields 42 then Just "created_at" else Nothing
            , if testBit touchedFields 43 then Just "updated_at" else Nothing
            ]
        setClauses = [col <> " = $" <> Text.pack (show i) | (i, col) <- zip [1..] setEntries]
        pkIdx = length setEntries + 1
        whereClause = \startIdx -> "id" <> " = $" <> Text.pack (show startIdx)
        returningClause = if returning then " RETURNING id, slug, name, rtsp_url, rtsp_template, rtsp_transport, host, port, username, password_enc, password_nonce, codec, rtsp_sub_url, rtsp_sub_template, use_substream_for_analysis, substream_codec, substream_width, substream_height, record_audio, analysis_fps, model_name, enabled, retention_hours, assigned_host, manual_assign, onvif_port, mgmt_proto, main_video_encoding, main_video_width, main_video_height, main_video_fps, main_video_bitrate_kbps, main_video_gov_length, sub_video_encoding, sub_video_width, sub_video_height, sub_video_fps, sub_video_bitrate_kbps, sub_video_gov_length, audio_encoding, audio_bitrate_kbps, audio_sample_rate_khz, created_at, updated_at" else ""
    in "UPDATE cameras SET " <> Text.intercalate ", " setClauses <> " WHERE " <> whereClause pkIdx <> returningClause


encoder :: Integer -> Encoders.Params Generated.ActualTypes.Camera
encoder touchedFields = mconcat (catMaybes
    [ if testBit touchedFields 1 then Just ((.slug) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , if testBit touchedFields 2 then Just ((.name) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , if testBit touchedFields 3 then Just ((.rtspUrl) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , if testBit touchedFields 4 then Just ((.rtspTemplate) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 5 then Just ((.rtspTransport) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , if testBit touchedFields 6 then Just ((.host) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 7 then Just ((.port) >$< Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 8 then Just ((.username) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 9 then Just ((.passwordEnc) >$< Encoders.param (Encoders.nullable ((\ (Database.PostgreSQL.Simple.Types.Binary bs) -> bs) >$< Encoders.bytea))) else Nothing
    , if testBit touchedFields 10 then Just ((.passwordNonce) >$< Encoders.param (Encoders.nullable ((\ (Database.PostgreSQL.Simple.Types.Binary bs) -> bs) >$< Encoders.bytea))) else Nothing
    , if testBit touchedFields 11 then Just ((.codec) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing
    , if testBit touchedFields 12 then Just ((.rtspSubUrl) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 13 then Just ((.rtspSubTemplate) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 14 then Just ((.useSubstreamForAnalysis) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 15 then Just ((.substreamCodec) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing
    , if testBit touchedFields 16 then Just ((.substreamWidth) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 17 then Just ((.substreamHeight) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 18 then Just ((.recordAudio) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 19 then Just ((.analysisFps) >$< Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 20 then Just ((.modelName) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , if testBit touchedFields 21 then Just ((.enabled) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 22 then Just ((.retentionHours) >$< Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 23 then Just ((.assignedHost) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 24 then Just ((.manualAssign) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 25 then Just ((.onvifPort) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 26 then Just ((.mgmtProto) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , if testBit touchedFields 27 then Just ((.mainVideoEncoding) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 28 then Just ((.mainVideoWidth) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 29 then Just ((.mainVideoHeight) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 30 then Just ((.mainVideoFps) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 31 then Just ((.mainVideoBitrateKbps) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 32 then Just ((.mainVideoGovLength) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 33 then Just ((.subVideoEncoding) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 34 then Just ((.subVideoWidth) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 35 then Just ((.subVideoHeight) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 36 then Just ((.subVideoFps) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 37 then Just ((.subVideoBitrateKbps) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 38 then Just ((.subVideoGovLength) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 39 then Just ((.audioEncoding) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 40 then Just ((.audioBitrateKbps) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 41 then Just ((.audioSampleRateKhz) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 42 then Just ((.createdAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    , if testBit touchedFields 43 then Just ((.updatedAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    ])
    <> ((.id) >$< Encoders.param (Encoders.nonNullable Mapping.encoder))


decoder :: Decoders.Result Generated.ActualTypes.Camera
decoder = Decoders.singleRow RowDecoder.rowDecoder
