-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}
module Generated.Statements.CreateManyHost (statement) where

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

import qualified Generated.Statements.RowDecoderHost as RowDecoder
import Data.Bits (testBit)
import Data.Maybe (catMaybes)
import qualified Data.Text as Text
import qualified Data.List as List
statement :: [Integer] -> Statement.Statement [Generated.ActualTypes.Host] [Generated.ActualTypes.Host]
statement touchedFieldsList = Statement.unpreparable (sql touchedFieldsList) (encoder touchedFieldsList) decoder

sql :: [Integer] -> Text
sql touchedFieldsList =
    let (valueGroups, _) = List.foldl' (\(gs, offset) tf ->
            let (g, offset') = valueGroup tf offset
            in (gs ++ [g], offset')
            ) ([], 1) touchedFieldsList
    in "INSERT INTO hosts (id, gpu_model, exec_providers, is_leader, last_health_at, health_json, created_at) VALUES "
        <> Text.intercalate ", " valueGroups
        <> " RETURNING id, gpu_model, exec_providers, is_leader, last_health_at, health_json, created_at"
  where
    columnMeta = [(0, False), (1, False), (2, True), (3, True), (4, False), (5, False), (6, True)]
    valueGroup tf offset =
        let step (parts, off) (bitIdx, hasDefault) =
                if hasDefault && not (testBit tf bitIdx)
                    then (parts ++ ["DEFAULT"], off)
                    else (parts ++ ["$" <> Text.pack (show off)], off + 1)
            (parts, offset') = List.foldl' step ([], offset) columnMeta
        in ("(" <> Text.intercalate ", " parts <> ")", offset')

encoder :: [Integer] -> Encoders.Params [Generated.ActualTypes.Host]
encoder touchedFieldsList = mconcat $ List.zipWith (\i tf -> contramap (!! i) (singleEncoder tf)) [0..] touchedFieldsList

singleEncoder :: Integer -> Encoders.Params Generated.ActualTypes.Host
singleEncoder touchedFields = mconcat $ catMaybes
    [ Just ((.id) >$< Encoders.param (Encoders.nonNullable Mapping.encoder))
    , Just ((.gpuModel) >$< Encoders.param (Encoders.nullable Encoders.text))
    , if testBit touchedFields 2 then Just ((.execProviders) >$< Encoders.param (Encoders.nonNullable (Encoders.foldableArray (Encoders.nonNullable Encoders.text)))) else Nothing
    , if testBit touchedFields 3 then Just ((.isLeader) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , Just ((.lastHealthAt) >$< Encoders.param (Encoders.nullable Encoders.timestamptz))
    , Just ((.healthJson) >$< Encoders.param (Encoders.nullable Encoders.jsonb))
    , if testBit touchedFields 6 then Just ((.createdAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    ]

decoder :: Decoders.Result [Generated.ActualTypes.Host]
decoder = Decoders.rowList RowDecoder.rowDecoder
