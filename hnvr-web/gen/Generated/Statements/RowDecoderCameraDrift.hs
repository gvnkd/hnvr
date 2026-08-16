{-# LANGUAGE ApplicativeDo, OverloadedLabels, TypeApplications, ScopedTypeVariables #-}
-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}
module Generated.Statements.RowDecoderCameraDrift (rowDecoder) where

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

import qualified IHP.QueryBuilder as QueryBuilder
import GHC.Records
rowDecoder :: Decoders.Row Generated.ActualTypes.CameraDrift
rowDecoder = do
    id <- Decoders.column (Decoders.nonNullable Mapping.decoder)
    cameraId <- Decoders.column (Decoders.nonNullable Decoders.uuid)
    configName <- Decoders.column (Decoders.nonNullable Decoders.text)
    fieldName <- Decoders.column (Decoders.nonNullable Decoders.text)
    desired <- Decoders.column (Decoders.nonNullable Decoders.text)
    observed <- Decoders.column (Decoders.nonNullable Decoders.text)
    firstSeenAt <- Decoders.column (Decoders.nonNullable Decoders.timestamptz)
    lastSeenAt <- Decoders.column (Decoders.nonNullable Decoders.timestamptz)
    pure (let theRecord = Generated.ActualTypes.CameraDrift id cameraId configName fieldName desired observed firstSeenAt lastSeenAt def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) } in theRecord)
