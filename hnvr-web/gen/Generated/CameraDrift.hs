-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.CameraDrift where
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
import qualified Generated.Statements.RowDecoderCameraDrift
import qualified Generated.Statements.CreateCameraDrift
import qualified Generated.Statements.UpdateCameraDrift
import qualified Generated.Statements.CreateManyCameraDrift
instance InputValue Generated.ActualTypes.CameraDrift where inputValue = IHP.ModelSupport.recordToInputValue

instance FromRow Generated.ActualTypes.CameraDrift where
    fromRow = do
        id <- field
        cameraId <- field
        configName <- field
        fieldName <- field
        desired <- field
        observed <- field
        firstSeenAt <- field
        lastSeenAt <- field
        let theRecord = Generated.ActualTypes.CameraDrift id cameraId configName fieldName desired observed firstSeenAt lastSeenAt def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
        pure theRecord

instance FromRowHasql Generated.ActualTypes.CameraDrift where
    hasqlRowDecoder = Generated.Statements.RowDecoderCameraDrift.rowDecoder

type instance GetModelName (CameraDrift') = "CameraDrift"

instance CanCreate Generated.ActualTypes.CameraDrift where
    create = createCameraDrift
    createMany = createManyCameraDrift
    createRecordDiscardResult = createRecordDiscardResultCameraDrift

createCameraDrift :: (?modelContext :: ModelContext) => Generated.ActualTypes.CameraDrift -> IO Generated.ActualTypes.CameraDrift
createCameraDrift model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateCameraDrift.statement touched)

createManyCameraDrift :: (?modelContext :: ModelContext) => [Generated.ActualTypes.CameraDrift] -> IO [Generated.ActualTypes.CameraDrift]
createManyCameraDrift [] = pure []
createManyCameraDrift models = do
    let pool = ?modelContext.hasqlPool
    let touchedList = List.map (\model -> model.meta.touchedFields) models
    sqlStatementHasql pool models (Generated.Statements.CreateManyCameraDrift.statement touchedList)

createRecordDiscardResultCameraDrift :: (?modelContext :: ModelContext) => Generated.ActualTypes.CameraDrift -> IO ()
createRecordDiscardResultCameraDrift model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateCameraDrift.discardResultStatement touched)

instance CanUpdate Generated.ActualTypes.CameraDrift where
    updateRecord = updateRecordCameraDrift
    updateRecordDiscardResult = updateRecordDiscardResultCameraDrift

updateRecordCameraDrift :: (?modelContext :: ModelContext) => Generated.ActualTypes.CameraDrift -> IO Generated.ActualTypes.CameraDrift
updateRecordCameraDrift model = do
    let touched = model.meta.touchedFields
    if touched == 0 then pure model else do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateCameraDrift.statement touched)

updateRecordDiscardResultCameraDrift :: (?modelContext :: ModelContext) => Generated.ActualTypes.CameraDrift -> IO ()
updateRecordDiscardResultCameraDrift model = do
    let touched = model.meta.touchedFields
    unless (touched == 0) $ do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateCameraDrift.discardResultStatement touched)

instance Record Generated.ActualTypes.CameraDrift where
    {-# INLINE newRecord #-}
    newRecord = Generated.ActualTypes.CameraDrift def def def def def def def def  def


instance QueryBuilder.FilterPrimaryKey "camera_drift" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (CameraDrift') (Id' "camera_drift") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "cameraId" (CameraDrift') UUID where
    {-# INLINE setField #-}
    setField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "configName" (CameraDrift') Text where
    {-# INLINE setField #-}
    setField newValue record = record { configName = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "fieldName" (CameraDrift') Text where
    {-# INLINE setField #-}
    setField newValue record = record { fieldName = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "desired" (CameraDrift') Text where
    {-# INLINE setField #-}
    setField newValue record = record { desired = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance SetField "observed" (CameraDrift') Text where
    {-# INLINE setField #-}
    setField newValue record = record { observed = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance SetField "firstSeenAt" (CameraDrift') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { firstSeenAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance SetField "lastSeenAt" (CameraDrift') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { lastSeenAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance SetField "meta" (CameraDrift') MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (CameraDrift') (CameraDrift') (Id' "camera_drift") (Id' "camera_drift") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "cameraId" (CameraDrift') (CameraDrift') UUID UUID where
    {-# INLINE updateField #-}
    updateField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "configName" (CameraDrift') (CameraDrift') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { configName = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "fieldName" (CameraDrift') (CameraDrift') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { fieldName = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "desired" (CameraDrift') (CameraDrift') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { desired = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance UpdateField "observed" (CameraDrift') (CameraDrift') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { observed = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance UpdateField "firstSeenAt" (CameraDrift') (CameraDrift') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { firstSeenAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance UpdateField "lastSeenAt" (CameraDrift') (CameraDrift') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { lastSeenAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance UpdateField "meta" (CameraDrift') (CameraDrift') MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (CameraDrift') where fieldBit = 1
instance FieldBit "cameraId" (CameraDrift') where fieldBit = 2
instance FieldBit "configName" (CameraDrift') where fieldBit = 4
instance FieldBit "fieldName" (CameraDrift') where fieldBit = 8
instance FieldBit "desired" (CameraDrift') where fieldBit = 16
instance FieldBit "observed" (CameraDrift') where fieldBit = 32
instance FieldBit "firstSeenAt" (CameraDrift') where fieldBit = 64
instance FieldBit "lastSeenAt" (CameraDrift') where fieldBit = 128


