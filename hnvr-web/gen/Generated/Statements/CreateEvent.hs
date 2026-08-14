-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}
module Generated.Statements.CreateEvent (statement, discardResultStatement) where

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

import qualified Generated.Statements.RowDecoderEvent as RowDecoder
import Data.Bits (testBit)
import Data.Maybe (catMaybes)
import qualified Data.Text as Text
statement :: Integer -> Statement.Statement Generated.ActualTypes.Event Generated.ActualTypes.Event
statement touchedFields = Statement.preparable (sql touchedFields True) (encoder touchedFields) decoder

discardResultStatement :: Integer -> Statement.Statement Generated.ActualTypes.Event ()
discardResultStatement touchedFields = Statement.preparable (sql touchedFields False) (encoder touchedFields) Decoders.noResult

sql :: Integer -> Bool -> Text
sql touchedFields returning =
    let entries = catMaybes
            [ if testBit touchedFields 0 then Just "id" else Nothing
            , Just "camera_id"
            , Just "rule_id"
            , Just "ts"
            , Just "kind"
            , Just "class_id"
            , Just "track_id"
            , Just "confidence"
            , Just "bbox"
            , Just "thumbnail_key"
            , Just "segment_ts"
            , Just "host_id"
            , Just "payload"
            , if testBit touchedFields 13 then Just "created_at" else Nothing
            ]
        columns = Text.intercalate ", " entries
        placeholders = Text.intercalate ", " ["$" <> Text.pack (show i) | i <- [1 .. length entries]]
        returningClause = if returning then " RETURNING id, camera_id, rule_id, ts, kind, class_id, track_id, confidence, bbox, thumbnail_key, segment_ts, host_id, payload, created_at" else ""
    in if null entries
        then "INSERT INTO events DEFAULT VALUES" <> returningClause
        else "INSERT INTO events (" <> columns <> ") VALUES (" <> placeholders <> ")" <> returningClause


encoder :: Integer -> Encoders.Params Generated.ActualTypes.Event
encoder touchedFields = mconcat $ catMaybes
    [ if testBit touchedFields 0 then Just ((.id) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing
    , Just ((.cameraId) >$< Encoders.param (Encoders.nonNullable Encoders.uuid))
    , Just ((.ruleId) >$< Encoders.param (Encoders.nullable Encoders.uuid))
    , Just ((.ts) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz))
    , Just ((.kind) >$< Encoders.param (Encoders.nonNullable Mapping.encoder))
    , Just ((.classId) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , Just ((.trackId) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4)))
    , Just ((.confidence) >$< Encoders.param (Encoders.nullable Encoders.float4))
    , Just ((.bbox) >$< Encoders.param (Encoders.nullable Encoders.jsonb))
    , Just ((.thumbnailKey) >$< Encoders.param (Encoders.nullable Encoders.text))
    , Just ((.segmentTs) >$< Encoders.param (Encoders.nullable Encoders.timestamptz))
    , Just ((.hostId) >$< Encoders.param (Encoders.nullable Encoders.text))
    , Just ((.payload) >$< Encoders.param (Encoders.nullable Encoders.jsonb))
    , if testBit touchedFields 13 then Just ((.createdAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    ]


decoder :: Decoders.Result Generated.ActualTypes.Event
decoder = Decoders.singleRow RowDecoder.rowDecoder
