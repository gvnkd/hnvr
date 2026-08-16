-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}
module Generated.Statements.CreateManyCamera (statement) where

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
import qualified Data.List as List
statement :: [Integer] -> Statement.Statement [Generated.ActualTypes.Camera] [Generated.ActualTypes.Camera]
statement touchedFieldsList = Statement.unpreparable (sql touchedFieldsList) (encoder touchedFieldsList) decoder

sql :: [Integer] -> Text
sql touchedFieldsList =
    let (valueGroups, _) = List.foldl' (\(gs, offset) tf ->
            let (g, offset') = valueGroup tf offset
            in (gs ++ [g], offset')
            ) ([], 1) touchedFieldsList
    in "INSERT INTO cameras (id, slug, name, rtsp_url, rtsp_template, rtsp_transport, host, port, username, password_enc, password_nonce, codec, rtsp_sub_url, rtsp_sub_template, use_substream_for_analysis, substream_codec, substream_width, substream_height, record_audio, analysis_fps, model_name, enabled, retention_hours, assigned_host, manual_assign, onvif_port, mgmt_proto, main_video_encoding, main_video_width, main_video_height, main_video_fps, main_video_bitrate_kbps, main_video_gov_length, sub_video_encoding, sub_video_width, sub_video_height, sub_video_fps, sub_video_bitrate_kbps, sub_video_gov_length, audio_encoding, audio_bitrate_kbps, audio_sample_rate_khz, created_at, updated_at) VALUES "
        <> Text.intercalate ", " valueGroups
        <> " RETURNING id, slug, name, rtsp_url, rtsp_template, rtsp_transport, host, port, username, password_enc, password_nonce, codec, rtsp_sub_url, rtsp_sub_template, use_substream_for_analysis, substream_codec, substream_width, substream_height, record_audio, analysis_fps, model_name, enabled, retention_hours, assigned_host, manual_assign, onvif_port, mgmt_proto, main_video_encoding, main_video_width, main_video_height, main_video_fps, main_video_bitrate_kbps, main_video_gov_length, sub_video_encoding, sub_video_width, sub_video_height, sub_video_fps, sub_video_bitrate_kbps, sub_video_gov_length, audio_encoding, audio_bitrate_kbps, audio_sample_rate_khz, created_at, updated_at"
  where
    columnMeta = [(0, True), (1, False), (2, False), (3, False), (4, False), (5, True), (6, False), (7, True), (8, False), (9, False), (10, False), (11, True), (12, False), (13, False), (14, True), (15, True), (16, False), (17, False), (18, True), (19, True), (20, True), (21, True), (22, True), (23, False), (24, True), (25, False), (26, True), (27, False), (28, False), (29, False), (30, False), (31, False), (32, False), (33, False), (34, False), (35, False), (36, False), (37, False), (38, False), (39, False), (40, False), (41, False), (42, True), (43, True)]
    valueGroup tf offset =
        let step (parts, off) (bitIdx, hasDefault) =
                if hasDefault && not (testBit tf bitIdx)
                    then (parts ++ ["DEFAULT"], off)
                    else (parts ++ ["$" <> Text.pack (show off)], off + 1)
            (parts, offset') = List.foldl' step ([], offset) columnMeta
        in ("(" <> Text.intercalate ", " parts <> ")", offset')

encoder :: [Integer] -> Encoders.Params [Generated.ActualTypes.Camera]
encoder touchedFieldsList = mconcat $ List.zipWith (\i tf -> contramap (!! i) (singleEncoder tf)) [0..] touchedFieldsList

singleEncoder :: Integer -> Encoders.Params Generated.ActualTypes.Camera
singleEncoder touchedFields = mconcat $ catMaybes
    [ if testBit touchedFields 0 then Just ((.id) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing
    , Just ((.slug) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    , Just ((.name) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    , Just ((.rtspUrl) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    , Just ((.rtspTemplate) >$< Encoders.param (Encoders.nullable Encoders.text))
    , if testBit touchedFields 5 then Just ((.rtspTransport) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , Just ((.host) >$< Encoders.param (Encoders.nullable Encoders.text))
    , if testBit touchedFields 7 then Just ((.port) >$< Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int4))) else Nothing
    , Just ((.username) >$< Encoders.param (Encoders.nullable Encoders.text))
    , Just ((.passwordEnc) >$< Encoders.param (Encoders.nullable ((\ (Database.PostgreSQL.Simple.Types.Binary bs) -> bs) >$< Encoders.bytea)))
    , Just ((.passwordNonce) >$< Encoders.param (Encoders.nullable ((\ (Database.PostgreSQL.Simple.Types.Binary bs) -> bs) >$< Encoders.bytea)))
    , if testBit touchedFields 11 then Just ((.codec) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing
    , Just ((.rtspSubUrl) >$< Encoders.param (Encoders.nullable Encoders.text))
    , Just ((.rtspSubTemplate) >$< Encoders.param (Encoders.nullable Encoders.text))
    , if testBit touchedFields 14 then Just ((.useSubstreamForAnalysis) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 15 then Just ((.substreamCodec) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing
    , Just ((.substreamWidth) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , Just ((.substreamHeight) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , if testBit touchedFields 18 then Just ((.recordAudio) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 19 then Just ((.analysisFps) >$< Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 20 then Just ((.modelName) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , if testBit touchedFields 21 then Just ((.enabled) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 22 then Just ((.retentionHours) >$< Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int4))) else Nothing
    , Just ((.assignedHost) >$< Encoders.param (Encoders.nullable Encoders.text))
    , if testBit touchedFields 24 then Just ((.manualAssign) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , Just ((.onvifPort) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , if testBit touchedFields 26 then Just ((.mgmtProto) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , Just ((.mainVideoEncoding) >$< Encoders.param (Encoders.nullable Encoders.text))
    , Just ((.mainVideoWidth) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , Just ((.mainVideoHeight) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , Just ((.mainVideoFps) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , Just ((.mainVideoBitrateKbps) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , Just ((.mainVideoGovLength) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , Just ((.subVideoEncoding) >$< Encoders.param (Encoders.nullable Encoders.text))
    , Just ((.subVideoWidth) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , Just ((.subVideoHeight) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , Just ((.subVideoFps) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , Just ((.subVideoBitrateKbps) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , Just ((.subVideoGovLength) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , Just ((.audioEncoding) >$< Encoders.param (Encoders.nullable Encoders.text))
    , Just ((.audioBitrateKbps) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , Just ((.audioSampleRateKhz) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , if testBit touchedFields 42 then Just ((.createdAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    , if testBit touchedFields 43 then Just ((.updatedAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    ]

decoder :: Decoders.Result [Generated.ActualTypes.Camera]
decoder = Decoders.rowList RowDecoder.rowDecoder
