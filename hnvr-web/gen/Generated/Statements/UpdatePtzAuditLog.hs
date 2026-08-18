-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}
module Generated.Statements.UpdatePtzAuditLog (statement, discardResultStatement) where

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

import qualified Generated.Statements.RowDecoderPtzAuditLog as RowDecoder
import Data.Bits (testBit)
import Data.Maybe (catMaybes)
import qualified Data.Text as Text
statement :: Integer -> Statement.Statement Generated.ActualTypes.PtzAuditLog Generated.ActualTypes.PtzAuditLog
statement touchedFields = Statement.preparable (sql touchedFields True) (encoder touchedFields) decoder

discardResultStatement :: Integer -> Statement.Statement Generated.ActualTypes.PtzAuditLog ()
discardResultStatement touchedFields = Statement.preparable (sql touchedFields False) (encoder touchedFields) Decoders.noResult

sql :: Integer -> Bool -> Text
sql touchedFields returning =
    let setEntries = catMaybes
            [ if testBit touchedFields 1 then Just "camera_id" else Nothing
            , if testBit touchedFields 2 then Just "user_id" else Nothing
            , if testBit touchedFields 3 then Just "command" else Nothing
            , if testBit touchedFields 4 then Just "args" else Nothing
            , if testBit touchedFields 5 then Just "source" else Nothing
            , if testBit touchedFields 6 then Just "duration_ms" else Nothing
            , if testBit touchedFields 7 then Just "ok" else Nothing
            , if testBit touchedFields 8 then Just "error" else Nothing
            , if testBit touchedFields 9 then Just "ts" else Nothing
            ]
        setClauses = [col <> " = $" <> Text.pack (show i) | (i, col) <- zip [1..] setEntries]
        pkIdx = length setEntries + 1
        whereClause = \startIdx -> "id" <> " = $" <> Text.pack (show startIdx)
        returningClause = if returning then " RETURNING id, camera_id, user_id, command, args, source, duration_ms, ok, error, ts" else ""
    in "UPDATE ptz_audit_log SET " <> Text.intercalate ", " setClauses <> " WHERE " <> whereClause pkIdx <> returningClause


encoder :: Integer -> Encoders.Params Generated.ActualTypes.PtzAuditLog
encoder touchedFields = mconcat (catMaybes
    [ if testBit touchedFields 1 then Just ((.cameraId) >$< Encoders.param (Encoders.nonNullable Encoders.uuid)) else Nothing
    , if testBit touchedFields 2 then Just ((.userId) >$< Encoders.param (Encoders.nullable Encoders.uuid)) else Nothing
    , if testBit touchedFields 3 then Just ((.command) >$< Encoders.param (Encoders.nonNullable Encoders.text)) else Nothing
    , if testBit touchedFields 4 then Just ((.args) >$< Encoders.param (Encoders.nullable Encoders.jsonb)) else Nothing
    , if testBit touchedFields 5 then Just ((.source) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing
    , if testBit touchedFields 6 then Just ((.durationMs) >$< Encoders.param (Encoders.nullable (fromIntegral >$< Encoders.int4))) else Nothing
    , if testBit touchedFields 7 then Just ((.ok) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , if testBit touchedFields 8 then Just ((.error) >$< Encoders.param (Encoders.nullable Encoders.text)) else Nothing
    , if testBit touchedFields 9 then Just ((.ts) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    ])
    <> ((.id) >$< Encoders.param (Encoders.nonNullable Mapping.encoder))


decoder :: Decoders.Result Generated.ActualTypes.PtzAuditLog
decoder = Decoders.singleRow RowDecoder.rowDecoder
