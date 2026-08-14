{-# LANGUAGE ApplicativeDo, OverloadedLabels, TypeApplications, ScopedTypeVariables #-}
-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}
module Generated.Statements.RowDecoderCamera (rowDecoder) where

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
rowDecoder :: Decoders.Row Generated.ActualTypes.Camera
rowDecoder = do
    id <- Decoders.column (Decoders.nonNullable Mapping.decoder)
    slug <- Decoders.column (Decoders.nonNullable Decoders.text)
    name <- Decoders.column (Decoders.nonNullable Decoders.text)
    rtspUrl <- Decoders.column (Decoders.nonNullable Decoders.text)
    rtspTemplate <- Decoders.column (Decoders.nullable Decoders.text)
    rtspTransport <- Decoders.column (Decoders.nonNullable Decoders.text)
    host <- Decoders.column (Decoders.nullable Decoders.text)
    port <- Decoders.column (Decoders.nonNullable (fromIntegral <$> Decoders.int4))
    username <- Decoders.column (Decoders.nullable Decoders.text)
    passwordEnc <- Decoders.column (Decoders.nullable (Database.PostgreSQL.Simple.Types.Binary <$> Decoders.bytea))
    passwordNonce <- Decoders.column (Decoders.nullable (Database.PostgreSQL.Simple.Types.Binary <$> Decoders.bytea))
    codec <- Decoders.column (Decoders.nonNullable Mapping.decoder)
    rtspSubUrl <- Decoders.column (Decoders.nullable Decoders.text)
    rtspSubTemplate <- Decoders.column (Decoders.nullable Decoders.text)
    useSubstreamForAnalysis <- Decoders.column (Decoders.nonNullable Decoders.bool)
    substreamCodec <- Decoders.column (Decoders.nonNullable Mapping.decoder)
    substreamWidth <- Decoders.column (Decoders.nullable (fromIntegral <$> Decoders.int4))
    substreamHeight <- Decoders.column (Decoders.nullable (fromIntegral <$> Decoders.int4))
    recordAudio <- Decoders.column (Decoders.nonNullable Decoders.bool)
    analysisFps <- Decoders.column (Decoders.nonNullable (fromIntegral <$> Decoders.int4))
    modelName <- Decoders.column (Decoders.nonNullable Decoders.text)
    enabled <- Decoders.column (Decoders.nonNullable Decoders.bool)
    retentionDays <- Decoders.column (Decoders.nonNullable (fromIntegral <$> Decoders.int4))
    assignedHost <- Decoders.column (Decoders.nullable Decoders.text)
    manualAssign <- Decoders.column (Decoders.nonNullable Decoders.bool)
    createdAt <- Decoders.column (Decoders.nonNullable Decoders.timestamptz)
    updatedAt <- Decoders.column (Decoders.nonNullable Decoders.timestamptz)
    pure (let theRecord = Generated.ActualTypes.Camera id slug name rtspUrl rtspTemplate rtspTransport host port username passwordEnc passwordNonce codec rtspSubUrl rtspSubTemplate useSubstreamForAnalysis substreamCodec substreamWidth substreamHeight recordAudio analysisFps modelName enabled retentionDays assignedHost manualAssign createdAt updatedAt def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) } in theRecord)
