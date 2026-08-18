-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.PtzAuditLog where
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
import qualified Generated.Statements.RowDecoderPtzAuditLog
import qualified Generated.Statements.CreatePtzAuditLog
import qualified Generated.Statements.UpdatePtzAuditLog
import qualified Generated.Statements.CreateManyPtzAuditLog
instance InputValue Generated.ActualTypes.PtzAuditLog where inputValue = IHP.ModelSupport.recordToInputValue

instance FromRow Generated.ActualTypes.PtzAuditLog where
    fromRow = do
        id <- field
        cameraId <- field
        userId <- field
        command <- field
        args <- field
        source <- field
        durationMs <- field
        ok <- field
        error <- field
        ts <- field
        let theRecord = Generated.ActualTypes.PtzAuditLog id cameraId userId command args source durationMs ok error ts def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
        pure theRecord

instance FromRowHasql Generated.ActualTypes.PtzAuditLog where
    hasqlRowDecoder = Generated.Statements.RowDecoderPtzAuditLog.rowDecoder

type instance GetModelName (PtzAuditLog') = "PtzAuditLog"

instance CanCreate Generated.ActualTypes.PtzAuditLog where
    create = createPtzAuditLog
    createMany = createManyPtzAuditLog
    createRecordDiscardResult = createRecordDiscardResultPtzAuditLog

createPtzAuditLog :: (?modelContext :: ModelContext) => Generated.ActualTypes.PtzAuditLog -> IO Generated.ActualTypes.PtzAuditLog
createPtzAuditLog model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreatePtzAuditLog.statement touched)

createManyPtzAuditLog :: (?modelContext :: ModelContext) => [Generated.ActualTypes.PtzAuditLog] -> IO [Generated.ActualTypes.PtzAuditLog]
createManyPtzAuditLog [] = pure []
createManyPtzAuditLog models = do
    let pool = ?modelContext.hasqlPool
    let touchedList = List.map (\model -> model.meta.touchedFields) models
    sqlStatementHasql pool models (Generated.Statements.CreateManyPtzAuditLog.statement touchedList)

createRecordDiscardResultPtzAuditLog :: (?modelContext :: ModelContext) => Generated.ActualTypes.PtzAuditLog -> IO ()
createRecordDiscardResultPtzAuditLog model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreatePtzAuditLog.discardResultStatement touched)

instance CanUpdate Generated.ActualTypes.PtzAuditLog where
    updateRecord = updateRecordPtzAuditLog
    updateRecordDiscardResult = updateRecordDiscardResultPtzAuditLog

updateRecordPtzAuditLog :: (?modelContext :: ModelContext) => Generated.ActualTypes.PtzAuditLog -> IO Generated.ActualTypes.PtzAuditLog
updateRecordPtzAuditLog model = do
    let touched = model.meta.touchedFields
    if touched == 0 then pure model else do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdatePtzAuditLog.statement touched)

updateRecordDiscardResultPtzAuditLog :: (?modelContext :: ModelContext) => Generated.ActualTypes.PtzAuditLog -> IO ()
updateRecordDiscardResultPtzAuditLog model = do
    let touched = model.meta.touchedFields
    unless (touched == 0) $ do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdatePtzAuditLog.discardResultStatement touched)

instance Record Generated.ActualTypes.PtzAuditLog where
    {-# INLINE newRecord #-}
    newRecord = Generated.ActualTypes.PtzAuditLog def def def def def def def True def def  def


instance QueryBuilder.FilterPrimaryKey "ptz_audit_log" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (PtzAuditLog') (Id' "ptz_audit_log") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "cameraId" (PtzAuditLog') UUID where
    {-# INLINE setField #-}
    setField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "userId" (PtzAuditLog') (Maybe UUID) where
    {-# INLINE setField #-}
    setField newValue record = record { userId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "command" (PtzAuditLog') Text where
    {-# INLINE setField #-}
    setField newValue record = record { command = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "args" (PtzAuditLog') (Maybe Data.Aeson.Value) where
    {-# INLINE setField #-}
    setField newValue record = record { args = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance SetField "source" (PtzAuditLog') PtzSource where
    {-# INLINE setField #-}
    setField newValue record = record { source = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance SetField "durationMs" (PtzAuditLog') (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { durationMs = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance SetField "ok" (PtzAuditLog') Bool where
    {-# INLINE setField #-}
    setField newValue record = record { ok = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance SetField "error" (PtzAuditLog') (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { error = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance SetField "ts" (PtzAuditLog') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { ts = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 512 } }
instance SetField "meta" (PtzAuditLog') MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (PtzAuditLog') (PtzAuditLog') (Id' "ptz_audit_log") (Id' "ptz_audit_log") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "cameraId" (PtzAuditLog') (PtzAuditLog') UUID UUID where
    {-# INLINE updateField #-}
    updateField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "userId" (PtzAuditLog') (PtzAuditLog') (Maybe UUID) (Maybe UUID) where
    {-# INLINE updateField #-}
    updateField newValue record = record { userId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "command" (PtzAuditLog') (PtzAuditLog') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { command = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "args" (PtzAuditLog') (PtzAuditLog') (Maybe Data.Aeson.Value) (Maybe Data.Aeson.Value) where
    {-# INLINE updateField #-}
    updateField newValue record = record { args = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance UpdateField "source" (PtzAuditLog') (PtzAuditLog') PtzSource PtzSource where
    {-# INLINE updateField #-}
    updateField newValue record = record { source = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance UpdateField "durationMs" (PtzAuditLog') (PtzAuditLog') (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { durationMs = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance UpdateField "ok" (PtzAuditLog') (PtzAuditLog') Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { ok = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance UpdateField "error" (PtzAuditLog') (PtzAuditLog') (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { error = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance UpdateField "ts" (PtzAuditLog') (PtzAuditLog') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { ts = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 512 } }
instance UpdateField "meta" (PtzAuditLog') (PtzAuditLog') MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (PtzAuditLog') where fieldBit = 1
instance FieldBit "cameraId" (PtzAuditLog') where fieldBit = 2
instance FieldBit "userId" (PtzAuditLog') where fieldBit = 4
instance FieldBit "command" (PtzAuditLog') where fieldBit = 8
instance FieldBit "args" (PtzAuditLog') where fieldBit = 16
instance FieldBit "source" (PtzAuditLog') where fieldBit = 32
instance FieldBit "durationMs" (PtzAuditLog') where fieldBit = 64
instance FieldBit "ok" (PtzAuditLog') where fieldBit = 128
instance FieldBit "error" (PtzAuditLog') where fieldBit = 256
instance FieldBit "ts" (PtzAuditLog') where fieldBit = 512


