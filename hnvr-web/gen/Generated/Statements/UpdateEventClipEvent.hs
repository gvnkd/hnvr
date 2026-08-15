-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}
module Generated.Statements.UpdateEventClipEvent (statement, discardResultStatement) where

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

import qualified Generated.Statements.RowDecoderEventClipEvent as RowDecoder
import Data.Bits (testBit)
import Data.Maybe (catMaybes)
import qualified Data.Text as Text
statement :: Integer -> Statement.Statement Generated.ActualTypes.EventClipEvent Generated.ActualTypes.EventClipEvent
statement touchedFields = Statement.preparable (sql touchedFields True) (encoder touchedFields) decoder

discardResultStatement :: Integer -> Statement.Statement Generated.ActualTypes.EventClipEvent ()
discardResultStatement touchedFields = Statement.preparable (sql touchedFields False) (encoder touchedFields) Decoders.noResult

sql :: Integer -> Bool -> Text
sql touchedFields returning =
    let setEntries = catMaybes
            [ if testBit touchedFields 1 then Just "clip_id" else Nothing
            , if testBit touchedFields 2 then Just "event_id" else Nothing
            , if testBit touchedFields 3 then Just "created_at" else Nothing
            ]
        setClauses = [col <> " = $" <> Text.pack (show i) | (i, col) <- zip [1..] setEntries]
        pkIdx = length setEntries + 1
        whereClause = \startIdx -> "id" <> " = $" <> Text.pack (show startIdx)
        returningClause = if returning then " RETURNING id, clip_id, event_id, created_at" else ""
    in "UPDATE event_clip_events SET " <> Text.intercalate ", " setClauses <> " WHERE " <> whereClause pkIdx <> returningClause


encoder :: Integer -> Encoders.Params Generated.ActualTypes.EventClipEvent
encoder touchedFields = mconcat (catMaybes
    [ if testBit touchedFields 1 then Just ((.clipId) >$< Encoders.param (Encoders.nonNullable Encoders.uuid)) else Nothing
    , if testBit touchedFields 2 then Just ((.eventId) >$< Encoders.param (Encoders.nonNullable Encoders.uuid)) else Nothing
    , if testBit touchedFields 3 then Just ((.createdAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    ])
    <> ((.id) >$< Encoders.param (Encoders.nonNullable Mapping.encoder))


decoder :: Decoders.Result Generated.ActualTypes.EventClipEvent
decoder = Decoders.singleRow RowDecoder.rowDecoder
