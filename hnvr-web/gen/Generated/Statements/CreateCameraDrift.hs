-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}
module Generated.Statements.CreateCameraDrift (statement, discardResultStatement) where

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
    let entries = catMaybes
            [ if testBit touchedFields 0 then Just "id" else Nothing
            , Just "camera_id"
            , Just "config_name"
            , Just "field_name"
            , Just "desired"
            , Just "observed"
            , if testBit touchedFields 6 then Just "first_seen_at" else Nothing
            , if testBit touchedFields 7 then Just "last_seen_at" else Nothing
            ]
        columns = Text.intercalate ", " entries
        placeholders = Text.intercalate ", " ["$" <> Text.pack (show i) | i <- [1 .. length entries]]
        returningClause = if returning then " RETURNING id, camera_id, config_name, field_name, desired, observed, first_seen_at, last_seen_at" else ""
    in if null entries
        then "INSERT INTO camera_drift DEFAULT VALUES" <> returningClause
        else "INSERT INTO camera_drift (" <> columns <> ") VALUES (" <> placeholders <> ")" <> returningClause


encoder :: Integer -> Encoders.Params Generated.ActualTypes.CameraDrift
encoder touchedFields = mconcat $ catMaybes
    [ if testBit touchedFields 0 then Just ((.id) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing
    , Just ((.cameraId) >$< Encoders.param (Encoders.nonNullable Encoders.uuid))
    , Just ((.configName) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    , Just ((.fieldName) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    , Just ((.desired) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    , Just ((.observed) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    , if testBit touchedFields 6 then Just ((.firstSeenAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    , if testBit touchedFields 7 then Just ((.lastSeenAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    ]


decoder :: Decoders.Result Generated.ActualTypes.CameraDrift
decoder = Decoders.singleRow RowDecoder.rowDecoder
