-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}

module Generated.Statements.CreateHost (statement, discardResultStatement) where

import qualified Data.Aeson
import Data.Bits (testBit)
import Data.Default (def)
import qualified Data.Dynamic
import Data.Functor.Contravariant (contramap, (>$<))
import Data.Int (Int16, Int32, Int64)
import Data.Maybe (catMaybes)
import Data.Scientific (Scientific)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Time.Calendar
import Data.Time.Clock (UTCTime)
import Data.Time.LocalTime (LocalTime, TimeOfDay)
import Data.UUID (UUID)
import qualified Database.PostgreSQL.Simple.Types
import Generated.ActualTypes
import Generated.Enums
import qualified Generated.Statements.RowDecoderHost as RowDecoder
import qualified Hasql.Decoders as Decoders
import qualified Hasql.Encoders as Encoders
import qualified Hasql.Mapping.IsScalar as Mapping
import Hasql.PostgresqlTypes ()
import qualified Hasql.Statement as Statement
import IHP.Job.Queue ()
import IHP.ModelSupport.Types (Id' (..), MetaBag (..))
import PostgresqlTypes.Inet (Inet)
import PostgresqlTypes.Interval (Interval)
import PostgresqlTypes.Point (Point)
import PostgresqlTypes.Polygon (Polygon)
import PostgresqlTypes.Tsvector (Tsvector)
import Prelude (Bool (..), Int, Integer, Maybe (..), fromIntegral, length, map, mconcat, not, null, pure, show, zip, (!!), ($), (&&), (*), (+), (++), (-), (.), (<$>), (<*>), (<>))

statement :: Integer -> Statement.Statement Generated.ActualTypes.Host Generated.ActualTypes.Host
statement touchedFields = Statement.preparable (sql touchedFields True) (encoder touchedFields) decoder

discardResultStatement :: Integer -> Statement.Statement Generated.ActualTypes.Host ()
discardResultStatement touchedFields = Statement.preparable (sql touchedFields False) (encoder touchedFields) Decoders.noResult

sql :: Integer -> Bool -> Text
sql touchedFields returning =
  let entries =
        catMaybes
          [ Just "id",
            Just "gpu_model",
            if testBit touchedFields 2 then Just "exec_providers" else Nothing,
            if testBit touchedFields 3 then Just "is_leader" else Nothing,
            Just "last_health_at",
            Just "health_json",
            if testBit touchedFields 6 then Just "created_at" else Nothing
          ]
      columns = Text.intercalate ", " entries
      placeholders = Text.intercalate ", " ["$" <> Text.pack (show i) | i <- [1 .. length entries]]
      returningClause = if returning then " RETURNING id, gpu_model, exec_providers, is_leader, last_health_at, health_json, created_at" else ""
   in if null entries
        then "INSERT INTO hosts DEFAULT VALUES" <> returningClause
        else "INSERT INTO hosts (" <> columns <> ") VALUES (" <> placeholders <> ")" <> returningClause

encoder :: Integer -> Encoders.Params Generated.ActualTypes.Host
encoder touchedFields =
  mconcat $
    catMaybes
      [ Just ((.id) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)),
        Just ((.gpuModel) >$< Encoders.param (Encoders.nullable Encoders.text)),
        if testBit touchedFields 2 then Just ((.execProviders) >$< Encoders.param (Encoders.nonNullable (Encoders.foldableArray (Encoders.nonNullable Encoders.text)))) else Nothing,
        if testBit touchedFields 3 then Just ((.isLeader) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing,
        Just ((.lastHealthAt) >$< Encoders.param (Encoders.nullable Encoders.timestamptz)),
        Just ((.healthJson) >$< Encoders.param (Encoders.nullable Encoders.jsonb)),
        if testBit touchedFields 6 then Just ((.createdAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
      ]

decoder :: Decoders.Result Generated.ActualTypes.Host
decoder = Decoders.singleRow RowDecoder.rowDecoder
