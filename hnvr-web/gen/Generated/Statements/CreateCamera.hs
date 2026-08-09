-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}
module Generated.Statements.CreateCamera (statement, discardResultStatement) where

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
    let entries = catMaybes
            [ if testBit touchedFields 0 then Just "id" else Nothing
            , Just "slug"
            , Just "name"
            , Just "rtsp_url"
            , Just "rtsp_template"
            , Just "host"
            , if testBit touchedFields 6 then Just "port" else Nothing
            , Just "username"
            , Just "password"
            , if testBit touchedFields 9 then Just "codec" else Nothing
            , Just "rtsp_sub_url"
            , Just "rtsp_sub_template"
            , if testBit touchedFields 12 then Just "use_substream_for_analysis" else Nothing
            , if testBit touchedFields 13 then Just "substream_codec" else Nothing
            , Just "substream_width"
            , Just "substream_height"
            , if testBit touchedFields 16 then Just "record_audio" else Nothing
            , if testBit touchedFields 17 then Just "analysis_fps" else Nothing
            , if testBit touchedFields 18 then Just "enabled" else Nothing
            , if testBit touchedFields 19 then Just "retention_days" else Nothing
            , Just "assigned_host"
            , if testBit touchedFields 21 then Just "manual_assign" else Nothing
            , if testBit touchedFields 22 then Just "created_at" else Nothing
            , if testBit touchedFields 23 then Just "updated_at" else Nothing
            ]
        columns = Text.intercalate ", " entries
        placeholders = Text.intercalate ", " ["$" <> Text.pack (show i) | i <- [1 .. length entries]]
        returningClause = if returning then " RETURNING id, slug, name, rtsp_url, rtsp_template, host, port, username, password, codec, rtsp_sub_url, rtsp_sub_template, use_substream_for_analysis, substream_codec, substream_width, substream_height, record_audio, analysis_fps, enabled, retention_days, assigned_host, manual_assign, created_at, updated_at" else ""
    in if null entries
        then "INSERT INTO cameras DEFAULT VALUES" <> returningClause
        else "INSERT INTO cameras (" <> columns <> ") VALUES (" <> placeholders <> ")" <> returningClause


encoder :: Integer -> Encoders.Params Generated.ActualTypes.Camera
encoder touchedFields = mconcat $ catMaybes
    [ if testBit touchedFields 0 then Just ((.id) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing
    , Just ((.slug) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    , Just ((.name) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    , Just ((.rtspUrl) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    , Just ((.rtspTemplate) >$< Encoders.param (Encoders.nullable Encoders.text))
    , Just ((.host) >$< Encoders.param (Encoders.nullable Encoders.text))
    , if testBit touchedFields 6 then Just ((.port) >$< Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int4))) else Nothing
    , Just ((.username) >$< Encoders.param (Encoders.nullable Encoders.text))
    , Just ((.password) >$< Encoders.param (Encoders.nullable Encoders.text))
    , if testBit touchedFields 9 then Just ((.codec) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing
    , Just ((.rtspSubUrl) >$< Encoders.param (Encoders.nullable Encoders.text))
    , Just ((.rtspSubTemplate) >$< Encoders.param (Encoders.nullable Encoders.text))
    , if testBit touchedFields 12 then Just ((.useSubstreamForAnalysis) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 13 then Just ((.substreamCodec) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing
    , Just ((.substreamWidth) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , Just ((.substreamHeight) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , if testBit touchedFields 16 then Just ((.recordAudio) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 17 then Just ((.analysisFps) >$< Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 18 then Just ((.enabled) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 19 then Just ((.retentionDays) >$< Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int4))) else Nothing
    , Just ((.assignedHost) >$< Encoders.param (Encoders.nullable Encoders.text))
    , if testBit touchedFields 21 then Just ((.manualAssign) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 22 then Just ((.createdAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    , if testBit touchedFields 23 then Just ((.updatedAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    ]


decoder :: Decoders.Result Generated.ActualTypes.Camera
decoder = Decoders.singleRow RowDecoder.rowDecoder
