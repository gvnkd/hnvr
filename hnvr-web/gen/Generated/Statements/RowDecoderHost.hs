{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE OverloadedLabels #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}

module Generated.Statements.RowDecoderHost (rowDecoder) where

import qualified Data.Aeson
import Data.Default (def)
import qualified Data.Dynamic
import Data.Functor.Contravariant (contramap, (>$<))
import Data.Int (Int16, Int32, Int64)
import Data.Scientific (Scientific)
import Data.Text (Text)
import qualified Data.Time.Calendar
import Data.Time.Clock (UTCTime)
import Data.Time.LocalTime (LocalTime, TimeOfDay)
import Data.UUID (UUID)
import qualified Database.PostgreSQL.Simple.Types
import GHC.Records
import Generated.ActualTypes
import Generated.Enums
import qualified Hasql.Decoders as Decoders
import qualified Hasql.Encoders as Encoders
import qualified Hasql.Mapping.IsScalar as Mapping
import Hasql.PostgresqlTypes ()
import qualified Hasql.Statement as Statement
import IHP.Job.Queue ()
import IHP.ModelSupport.Types (Id' (..), MetaBag (..))
import qualified IHP.QueryBuilder as QueryBuilder
import PostgresqlTypes.Inet (Inet)
import PostgresqlTypes.Interval (Interval)
import PostgresqlTypes.Point (Point)
import PostgresqlTypes.Polygon (Polygon)
import PostgresqlTypes.Tsvector (Tsvector)
import Prelude (Bool (..), Int, Integer, Maybe (..), fromIntegral, length, map, mconcat, not, null, pure, show, zip, (!!), ($), (&&), (*), (+), (++), (-), (.), (<$>), (<*>), (<>))

rowDecoder :: Decoders.Row Generated.ActualTypes.Host
rowDecoder = do
  id <- Decoders.column (Decoders.nonNullable Mapping.decoder)
  gpuModel <- Decoders.column (Decoders.nullable Decoders.text)
  execProviders <- Decoders.column (Decoders.nonNullable (Decoders.listArray (Decoders.nonNullable Decoders.text)))
  isLeader <- Decoders.column (Decoders.nonNullable Decoders.bool)
  lastHealthAt <- Decoders.column (Decoders.nullable Decoders.timestamptz)
  healthJson <- Decoders.column (Decoders.nullable Decoders.jsonb)
  createdAt <- Decoders.column (Decoders.nonNullable Decoders.timestamptz)
  pure (let theRecord = Generated.ActualTypes.Host id gpuModel execProviders isLeader lastHealthAt healthJson createdAt def {originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord)} in theRecord)
