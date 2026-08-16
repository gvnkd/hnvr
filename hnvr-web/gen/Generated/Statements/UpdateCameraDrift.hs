-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}
module Generated.Statements.UpdateCameraDrift (statement, discardResultStatement) where

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

import qualified Generated.Statements.RowDecoderCameraDrift as RowDecoder
import Data.Bits (testBit)
import Data.Maybe (catMaybes)
import qualified Data.Text as Text
statement :: Integer -> Statement.Statement Generated.ActualTypes.CameraDrift Generated.ActualTypes.CameraDrift
statement touchedFields = Statement.preparable (sql touchedFields True) (encoder touchedFields) decoder

discardResultStatement :: Integer -> Statement.Statement Generated.ActualTypes.CameraDrift ()
discardResultStatement touchedFields = Statement.preparable (sql touchedFields False) (encoder touchedFields) Decoders.noResult

sql :: Integer -> Bool -> Text
sql touchedFields returning =
    let setEntries = catMaybes
            [ if testBit touchedFields 1 then Just "camera_id" else Nothing
            , if testBit touchedFields 2 then Just "config_name" else Nothing
            , if testBit touchedFields 3 then Just "field_name" else Nothing
            , if testBit touchedFields 4 then Just "desired" else Nothing
            , if testBit touchedFields 5 then Just "observed" else Nothing
            , if testBit touchedFields 6 then Just "first_seen_at" else Nothing
            , if testBit touchedFields 7 then Just "last_seen_at" else Nothing
            ]
        setClauses = [col <> " = $" <> Text.pack (show i) | (i, col) <- zip [1..] setEntries]
        pkIdx = length setEntries + 1
        whereClause = \startIdx -> "id" <> " = $" <> Text.pack (show startIdx)
        returningClause = if returning then " RETURNING id, camera_id, config_name, field_name, desired, observed, first_seen_at, last_seen_at" else ""
    in "UPDATE camera_drift SET " <> Text.intercalate ", " setClauses <> " WHERE " <> whereClause pkIdx <> returningClause


encoder :: Integer -> Encoders.Params Generated.ActualTypes.CameraDrift
encoder touchedFields = mconcat (catMaybes
    [ if testBit touchedFields 1 then Just ((.cameraId) >$< Encoders.param (Encoders.nonNullable Encoders.uuid)) else Nothing
    , if testBit touchedFields 2 then Just ((.configName) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , if testBit touchedFields 3 then Just ((.fieldName) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , if testBit touchedFields 4 then Just ((.desired) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , if testBit touchedFields 5 then Just ((.observed) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , if testBit touchedFields 6 then Just ((.firstSeenAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    , if testBit touchedFields 7 then Just ((.lastSeenAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    ])
    <> ((.id) >$< Encoders.param (Encoders.nonNullable Mapping.encoder))


decoder :: Decoders.Result Generated.ActualTypes.CameraDrift
decoder = Decoders.singleRow RowDecoder.rowDecoder
