-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE ConstraintKinds #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE DataKinds #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE FlexibleInstances #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE InstanceSigs #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE MultiParamTypeClasses #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE StandaloneDeriving #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeFamilies #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeOperators #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}

module Generated.Host where

import qualified Control.DeepSeq as DeepSeq
import Control.Monad (unless)
import CorePrelude hiding (id)
import qualified Data.Aeson
import Data.Bits ((.&.), (.|.))
import qualified Data.ByteString as ByteString
import Data.Data
import Data.Default
import qualified Data.Dynamic
import qualified Data.List as List
import qualified Data.Proxy
import Data.Scientific
import qualified Data.String.Conversions
import qualified Data.Text.Encoding
import qualified Data.Time.Calendar
import Data.Time.Clock
import Data.Time.LocalTime
import Data.UUID (UUID)
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.FromField hiding (Field, name)
import Database.PostgreSQL.Simple.FromRow
import Database.PostgreSQL.Simple.ToField hiding (Field)
import Database.PostgreSQL.Simple.Types (Binary (..), Query (Query))
import qualified Database.PostgreSQL.Simple.Types
import GHC.Records
import GHC.TypeLits
import Generated.ActualTypes
import qualified Generated.Statements.CreateHost
import qualified Generated.Statements.CreateManyHost
import qualified Generated.Statements.RowDecoderHost
import qualified Generated.Statements.UpdateHost
import qualified Hasql.Decoders as Decoders
import qualified Hasql.Encoders
import qualified Hasql.Implicits.Encoders
import qualified Hasql.Mapping.IsScalar as Mapping
import Hasql.PostgresqlTypes ()
import qualified IHP.Controller.Param
import IHP.HaskellSupport
import IHP.Hasql.Encoders ()
import IHP.Hasql.FromRow (FromRowHasql (..))
import IHP.Job.Queue (textToEnumJobStatus)
import IHP.Job.Types
import IHP.ModelSupport
import qualified IHP.QueryBuilder as QueryBuilder

instance InputValue Generated.ActualTypes.Host where inputValue = IHP.ModelSupport.recordToInputValue

instance FromRow Generated.ActualTypes.Host where
  fromRow = do
    id <- field
    gpuModel <- field
    execProviders <- field
    isLeader <- field
    lastHealthAt <- field
    healthJson <- field
    createdAt <- field
    let theRecord = Generated.ActualTypes.Host id gpuModel execProviders isLeader lastHealthAt healthJson createdAt def {originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord)}
    pure theRecord

instance FromRowHasql Generated.ActualTypes.Host where
  hasqlRowDecoder = Generated.Statements.RowDecoderHost.rowDecoder

type instance GetModelName (Host') = "Host"

instance CanCreate Generated.ActualTypes.Host where
  create = createHost
  createMany = createManyHost
  createRecordDiscardResult = createRecordDiscardResultHost

createHost :: (?modelContext :: ModelContext) => Generated.ActualTypes.Host -> IO Generated.ActualTypes.Host
createHost model = do
  let pool = ?modelContext.hasqlPool
  let touched = model.meta.touchedFields
  sqlStatementHasql pool model (Generated.Statements.CreateHost.statement touched)

createManyHost :: (?modelContext :: ModelContext) => [Generated.ActualTypes.Host] -> IO [Generated.ActualTypes.Host]
createManyHost [] = pure []
createManyHost models = do
  let pool = ?modelContext.hasqlPool
  let touchedList = List.map (\model -> model.meta.touchedFields) models
  sqlStatementHasql pool models (Generated.Statements.CreateManyHost.statement touchedList)

createRecordDiscardResultHost :: (?modelContext :: ModelContext) => Generated.ActualTypes.Host -> IO ()
createRecordDiscardResultHost model = do
  let pool = ?modelContext.hasqlPool
  let touched = model.meta.touchedFields
  sqlStatementHasql pool model (Generated.Statements.CreateHost.discardResultStatement touched)

instance CanUpdate Generated.ActualTypes.Host where
  updateRecord = updateRecordHost
  updateRecordDiscardResult = updateRecordDiscardResultHost

updateRecordHost :: (?modelContext :: ModelContext) => Generated.ActualTypes.Host -> IO Generated.ActualTypes.Host
updateRecordHost model = do
  let touched = model.meta.touchedFields
  if touched == 0
    then pure model
    else do
      let pool = ?modelContext.hasqlPool
      sqlStatementHasql pool model (Generated.Statements.UpdateHost.statement touched)

updateRecordDiscardResultHost :: (?modelContext :: ModelContext) => Generated.ActualTypes.Host -> IO ()
updateRecordDiscardResultHost model = do
  let touched = model.meta.touchedFields
  unless (touched == 0) $ do
    let pool = ?modelContext.hasqlPool
    sqlStatementHasql pool model (Generated.Statements.UpdateHost.discardResultStatement touched)

instance Record Generated.ActualTypes.Host where
  {-# INLINE newRecord #-}
  newRecord = Generated.ActualTypes.Host def def def False def def def def

instance QueryBuilder.FilterPrimaryKey "hosts" where
  filterWhereId id builder =
    builder |> QueryBuilder.filterWhere (#id, id)
  {-# INLINE filterWhereId #-}

instance SetField "id" (Host') (Id' "hosts") where
  {-# INLINE setField #-}
  setField newValue record = record {id = newValue, meta = record.meta {touchedFields = record.meta.touchedFields .|. 1}}

instance SetField "gpuModel" (Host') (Maybe Text) where
  {-# INLINE setField #-}
  setField newValue record = record {gpuModel = newValue, meta = record.meta {touchedFields = record.meta.touchedFields .|. 2}}

instance SetField "execProviders" (Host') [Text] where
  {-# INLINE setField #-}
  setField newValue record = record {execProviders = newValue, meta = record.meta {touchedFields = record.meta.touchedFields .|. 4}}

instance SetField "isLeader" (Host') Bool where
  {-# INLINE setField #-}
  setField newValue record = record {isLeader = newValue, meta = record.meta {touchedFields = record.meta.touchedFields .|. 8}}

instance SetField "lastHealthAt" (Host') (Maybe UTCTime) where
  {-# INLINE setField #-}
  setField newValue record = record {lastHealthAt = newValue, meta = record.meta {touchedFields = record.meta.touchedFields .|. 16}}

instance SetField "healthJson" (Host') (Maybe Data.Aeson.Value) where
  {-# INLINE setField #-}
  setField newValue record = record {healthJson = newValue, meta = record.meta {touchedFields = record.meta.touchedFields .|. 32}}

instance SetField "createdAt" (Host') UTCTime where
  {-# INLINE setField #-}
  setField newValue record = record {createdAt = newValue, meta = record.meta {touchedFields = record.meta.touchedFields .|. 64}}

instance SetField "meta" (Host') MetaBag where
  {-# INLINE setField #-}
  setField newValue record = record {meta = newValue}

instance UpdateField "id" (Host') (Host') (Id' "hosts") (Id' "hosts") where
  {-# INLINE updateField #-}
  updateField newValue record = record {id = newValue, meta = record.meta {touchedFields = record.meta.touchedFields .|. 1}}

instance UpdateField "gpuModel" (Host') (Host') (Maybe Text) (Maybe Text) where
  {-# INLINE updateField #-}
  updateField newValue record = record {gpuModel = newValue, meta = record.meta {touchedFields = record.meta.touchedFields .|. 2}}

instance UpdateField "execProviders" (Host') (Host') [Text] [Text] where
  {-# INLINE updateField #-}
  updateField newValue record = record {execProviders = newValue, meta = record.meta {touchedFields = record.meta.touchedFields .|. 4}}

instance UpdateField "isLeader" (Host') (Host') Bool Bool where
  {-# INLINE updateField #-}
  updateField newValue record = record {isLeader = newValue, meta = record.meta {touchedFields = record.meta.touchedFields .|. 8}}

instance UpdateField "lastHealthAt" (Host') (Host') (Maybe UTCTime) (Maybe UTCTime) where
  {-# INLINE updateField #-}
  updateField newValue record = record {lastHealthAt = newValue, meta = record.meta {touchedFields = record.meta.touchedFields .|. 16}}

instance UpdateField "healthJson" (Host') (Host') (Maybe Data.Aeson.Value) (Maybe Data.Aeson.Value) where
  {-# INLINE updateField #-}
  updateField newValue record = record {healthJson = newValue, meta = record.meta {touchedFields = record.meta.touchedFields .|. 32}}

instance UpdateField "createdAt" (Host') (Host') UTCTime UTCTime where
  {-# INLINE updateField #-}
  updateField newValue record = record {createdAt = newValue, meta = record.meta {touchedFields = record.meta.touchedFields .|. 64}}

instance UpdateField "meta" (Host') (Host') MetaBag MetaBag where
  {-# INLINE updateField #-}
  updateField newValue record = record {meta = newValue}

instance FieldBit "id" (Host') where fieldBit = 1

instance FieldBit "gpuModel" (Host') where fieldBit = 2

instance FieldBit "execProviders" (Host') where fieldBit = 4

instance FieldBit "isLeader" (Host') where fieldBit = 8

instance FieldBit "lastHealthAt" (Host') where fieldBit = 16

instance FieldBit "healthJson" (Host') where fieldBit = 32

instance FieldBit "createdAt" (Host') where fieldBit = 64
