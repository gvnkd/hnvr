-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.Host where
import IHP.HaskellSupport
import IHP.ModelSupport
import CorePrelude hiding (id)
import Data.Time.Clock
import Data.Time.LocalTime
import qualified Data.Time.Calendar
import qualified Data.List as List
import qualified Data.ByteString as ByteString
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.FromRow
import Database.PostgreSQL.Simple.FromField hiding (Field, name)
import Database.PostgreSQL.Simple.ToField hiding (Field)
import qualified IHP.Controller.Param
import GHC.TypeLits
import Data.UUID (UUID)
import Data.Default
import qualified IHP.QueryBuilder as QueryBuilder
import qualified Data.Proxy
import GHC.Records
import Data.Data
import qualified Data.String.Conversions
import qualified Data.Text.Encoding
import qualified Data.Aeson
import Database.PostgreSQL.Simple.Types (Query (Query), Binary ( .. ))
import qualified Database.PostgreSQL.Simple.Types
import IHP.Job.Types
import IHP.Job.Queue (textToEnumJobStatus)
import qualified Control.DeepSeq as DeepSeq
import qualified Data.Dynamic
import Data.Scientific
import IHP.Hasql.FromRow (FromRowHasql(..))
import qualified Hasql.Decoders as Decoders
import qualified Hasql.Encoders
import qualified Hasql.Implicits.Encoders
import IHP.Hasql.Encoders ()
import qualified Hasql.Mapping.IsScalar as Mapping
import Hasql.PostgresqlTypes ()
import Data.Bits ((.&.), (.|.))
import Control.Monad (unless)
import Generated.ActualTypes
import qualified Generated.Statements.RowDecoderHost
import qualified Generated.Statements.CreateHost
import qualified Generated.Statements.UpdateHost
import qualified Generated.Statements.CreateManyHost
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
        let theRecord = Generated.ActualTypes.Host id gpuModel execProviders isLeader lastHealthAt healthJson createdAt def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
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
    if touched == 0 then pure model else do
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
    newRecord = Generated.ActualTypes.Host def def def False def def def  def


instance QueryBuilder.FilterPrimaryKey "hosts" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (Host') (Id' "hosts") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "gpuModel" (Host') (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { gpuModel = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "execProviders" (Host') [Text] where
    {-# INLINE setField #-}
    setField newValue record = record { execProviders = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "isLeader" (Host') Bool where
    {-# INLINE setField #-}
    setField newValue record = record { isLeader = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "lastHealthAt" (Host') (Maybe UTCTime) where
    {-# INLINE setField #-}
    setField newValue record = record { lastHealthAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance SetField "healthJson" (Host') (Maybe Data.Aeson.Value) where
    {-# INLINE setField #-}
    setField newValue record = record { healthJson = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance SetField "createdAt" (Host') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance SetField "meta" (Host') MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (Host') (Host') (Id' "hosts") (Id' "hosts") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "gpuModel" (Host') (Host') (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { gpuModel = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "execProviders" (Host') (Host') [Text] [Text] where
    {-# INLINE updateField #-}
    updateField newValue record = record { execProviders = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "isLeader" (Host') (Host') Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { isLeader = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "lastHealthAt" (Host') (Host') (Maybe UTCTime) (Maybe UTCTime) where
    {-# INLINE updateField #-}
    updateField newValue record = record { lastHealthAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance UpdateField "healthJson" (Host') (Host') (Maybe Data.Aeson.Value) (Maybe Data.Aeson.Value) where
    {-# INLINE updateField #-}
    updateField newValue record = record { healthJson = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance UpdateField "createdAt" (Host') (Host') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance UpdateField "meta" (Host') (Host') MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (Host') where fieldBit = 1
instance FieldBit "gpuModel" (Host') where fieldBit = 2
instance FieldBit "execProviders" (Host') where fieldBit = 4
instance FieldBit "isLeader" (Host') where fieldBit = 8
instance FieldBit "lastHealthAt" (Host') where fieldBit = 16
instance FieldBit "healthJson" (Host') where fieldBit = 32
instance FieldBit "createdAt" (Host') where fieldBit = 64


