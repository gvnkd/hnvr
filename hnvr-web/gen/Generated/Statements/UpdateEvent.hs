-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}
module Generated.Statements.UpdateEvent (statement, discardResultStatement) where

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
    let setEntries = catMaybes
            [ if testBit touchedFields 1 then Just "camera_id" else Nothing
            , if testBit touchedFields 2 then Just "rule_id" else Nothing
            , if testBit touchedFields 3 then Just "ts" else Nothing
            , if testBit touchedFields 4 then Just "kind" else Nothing
            , if testBit touchedFields 5 then Just "class_id" else Nothing
            , if testBit touchedFields 6 then Just "track_id" else Nothing
            , if testBit touchedFields 7 then Just "confidence" else Nothing
            , if testBit touchedFields 8 then Just "bbox" else Nothing
            , if testBit touchedFields 9 then Just "thumbnail_key" else Nothing
            , if testBit touchedFields 10 then Just "segment_ts" else Nothing
            , if testBit touchedFields 11 then Just "host_id" else Nothing
            , if testBit touchedFields 12 then Just "payload" else Nothing
            , if testBit touchedFields 13 then Just "created_at" else Nothing
            ]
        setClauses = [col <> " = $" <> Text.pack (show i) | (i, col) <- zip [1..] setEntries]
        pkIdx = length setEntries + 1
        whereClause = \startIdx -> "id" <> " = $" <> Text.pack (show startIdx)
        returningClause = if returning then " RETURNING id, camera_id, rule_id, ts, kind, class_id, track_id, confidence, bbox, thumbnail_key, segment_ts, host_id, payload, created_at" else ""
    in "UPDATE events SET " <> Text.intercalate ", " setClauses <> " WHERE " <> whereClause pkIdx <> returningClause


encoder :: Integer -> Encoders.Params Generated.ActualTypes.Event
encoder touchedFields = mconcat (catMaybes
    [ if testBit touchedFields 1 then Just ((.cameraId) >$< Encoders.param (Encoders.nonNullable Encoders.uuid)) else Nothing
    , if testBit touchedFields 2 then Just ((.ruleId) >$< Encoders.param (Encoders.nullable Encoders.uuid)) else Nothing
    , if testBit touchedFields 3 then Just ((.ts) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    , if testBit touchedFields 4 then Just ((.kind) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing
    , if testBit touchedFields 5 then Just ((.classId) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 6 then Just ((.trackId) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 7 then Just ((.confidence) >$< Encoders.param (Encoders.nullable Encoders.float4)) else Nothing
    , if testBit touchedFields 8 then Just ((.bbox) >$< Encoders.param (Encoders.nullable Encoders.jsonb)) else Nothing
    , if testBit touchedFields 9 then Just ((.thumbnailKey) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 10 then Just ((.segmentTs) >$< Encoders.param (Encoders.nullable Encoders.timestamptz)) else Nothing
    , if testBit touchedFields 11 then Just ((.hostId) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 12 then Just ((.payload) >$< Encoders.param (Encoders.nullable Encoders.jsonb)) else Nothing
    , if testBit touchedFields 13 then Just ((.createdAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    ])
    <> ((.id) >$< Encoders.param (Encoders.nonNullable Mapping.encoder))


decoder :: Decoders.Result Generated.ActualTypes.Event
decoder = Decoders.singleRow RowDecoder.rowDecoder
