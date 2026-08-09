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
            , if testBit touchedFields 5 then Just "host" else Nothing
            , if testBit touchedFields 6 then Just "port" else Nothing
            , if testBit touchedFields 7 then Just "username" else Nothing
            , if testBit touchedFields 8 then Just "password_enc" else Nothing
            , if testBit touchedFields 9 then Just "password_nonce" else Nothing
            , if testBit touchedFields 10 then Just "codec" else Nothing
            , if testBit touchedFields 11 then Just "rtsp_sub_url" else Nothing
            , if testBit touchedFields 12 then Just "rtsp_sub_template" else Nothing
            , if testBit touchedFields 13 then Just "use_substream_for_analysis" else Nothing
            , if testBit touchedFields 14 then Just "substream_codec" else Nothing
            , if testBit touchedFields 15 then Just "substream_width" else Nothing
            , if testBit touchedFields 16 then Just "substream_height" else Nothing
            , if testBit touchedFields 17 then Just "record_audio" else Nothing
            , if testBit touchedFields 18 then Just "analysis_fps" else Nothing
            , if testBit touchedFields 19 then Just "enabled" else Nothing
            , if testBit touchedFields 20 then Just "retention_days" else Nothing
            , if testBit touchedFields 21 then Just "assigned_host" else Nothing
            , if testBit touchedFields 22 then Just "manual_assign" else Nothing
            , if testBit touchedFields 23 then Just "created_at" else Nothing
            , if testBit touchedFields 24 then Just "updated_at" else Nothing
            ]
        setClauses = [col <> " = $" <> Text.pack (show i) | (i, col) <- zip [1..] setEntries]
        pkIdx = length setEntries + 1
        whereClause = \startIdx -> "id" <> " = $" <> Text.pack (show startIdx)
        returningClause = if returning then " RETURNING id, slug, name, rtsp_url, rtsp_template, host, port, username, password_enc, password_nonce, codec, rtsp_sub_url, rtsp_sub_template, use_substream_for_analysis, substream_codec, substream_width, substream_height, record_audio, analysis_fps, enabled, retention_days, assigned_host, manual_assign, created_at, updated_at" else ""
    in "UPDATE cameras SET " <> Text.intercalate ", " setClauses <> " WHERE " <> whereClause pkIdx <> returningClause


encoder :: Integer -> Encoders.Params Generated.ActualTypes.Camera
encoder touchedFields = mconcat (catMaybes
    [ if testBit touchedFields 1 then Just ((.slug) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , if testBit touchedFields 2 then Just ((.name) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , if testBit touchedFields 3 then Just ((.rtspUrl) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , if testBit touchedFields 4 then Just ((.rtspTemplate) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 5 then Just ((.host) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 6 then Just ((.port) >$< Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 7 then Just ((.username) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 8 then Just ((.passwordEnc) >$< Encoders.param (Encoders.nullable ((\ (Database.PostgreSQL.Simple.Types.Binary bs) -> bs) >$< Encoders.bytea))) else Nothing
    , if testBit touchedFields 9 then Just ((.passwordNonce) >$< Encoders.param (Encoders.nullable ((\ (Database.PostgreSQL.Simple.Types.Binary bs) -> bs) >$< Encoders.bytea))) else Nothing
    , if testBit touchedFields 10 then Just ((.codec) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing
    , if testBit touchedFields 11 then Just ((.rtspSubUrl) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 12 then Just ((.rtspSubTemplate) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 13 then Just ((.useSubstreamForAnalysis) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 14 then Just ((.substreamCodec) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing
    , if testBit touchedFields 15 then Just ((.substreamWidth) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 16 then Just ((.substreamHeight) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 17 then Just ((.recordAudio) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 18 then Just ((.analysisFps) >$< Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 19 then Just ((.enabled) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 20 then Just ((.retentionDays) >$< Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 21 then Just ((.assignedHost) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 22 then Just ((.manualAssign) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 23 then Just ((.createdAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    , if testBit touchedFields 24 then Just ((.updatedAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    ])
    <> ((.id) >$< Encoders.param (Encoders.nonNullable Mapping.encoder))


decoder :: Decoders.Result Generated.ActualTypes.Camera
decoder = Decoders.singleRow RowDecoder.rowDecoder
