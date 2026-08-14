-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.AuditLog where
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
import qualified Generated.Statements.RowDecoderAuditLog
import qualified Generated.Statements.CreateAuditLog
import qualified Generated.Statements.UpdateAuditLog
import qualified Generated.Statements.CreateManyAuditLog
instance InputValue Generated.ActualTypes.AuditLog where inputValue = IHP.ModelSupport.recordToInputValue

instance FromRow Generated.ActualTypes.AuditLog where
    fromRow = do
        id <- field
        userId <- field
        action <- field
        targetType <- field
        targetId <- field
        payload <- field
        ts <- field
        let theRecord = Generated.ActualTypes.AuditLog id userId action targetType targetId payload ts def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
        pure theRecord

instance FromRowHasql Generated.ActualTypes.AuditLog where
    hasqlRowDecoder = Generated.Statements.RowDecoderAuditLog.rowDecoder

type instance GetModelName (AuditLog') = "AuditLog"

instance CanCreate Generated.ActualTypes.AuditLog where
    create = createAuditLog
    createMany = createManyAuditLog
    createRecordDiscardResult = createRecordDiscardResultAuditLog

createAuditLog :: (?modelContext :: ModelContext) => Generated.ActualTypes.AuditLog -> IO Generated.ActualTypes.AuditLog
createAuditLog model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateAuditLog.statement touched)

createManyAuditLog :: (?modelContext :: ModelContext) => [Generated.ActualTypes.AuditLog] -> IO [Generated.ActualTypes.AuditLog]
createManyAuditLog [] = pure []
createManyAuditLog models = do
    let pool = ?modelContext.hasqlPool
    let touchedList = List.map (\model -> model.meta.touchedFields) models
    sqlStatementHasql pool models (Generated.Statements.CreateManyAuditLog.statement touchedList)

createRecordDiscardResultAuditLog :: (?modelContext :: ModelContext) => Generated.ActualTypes.AuditLog -> IO ()
createRecordDiscardResultAuditLog model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateAuditLog.discardResultStatement touched)

instance CanUpdate Generated.ActualTypes.AuditLog where
    updateRecord = updateRecordAuditLog
    updateRecordDiscardResult = updateRecordDiscardResultAuditLog

updateRecordAuditLog :: (?modelContext :: ModelContext) => Generated.ActualTypes.AuditLog -> IO Generated.ActualTypes.AuditLog
updateRecordAuditLog model = do
    let touched = model.meta.touchedFields
    if touched == 0 then pure model else do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateAuditLog.statement touched)

updateRecordDiscardResultAuditLog :: (?modelContext :: ModelContext) => Generated.ActualTypes.AuditLog -> IO ()
updateRecordDiscardResultAuditLog model = do
    let touched = model.meta.touchedFields
    unless (touched == 0) $ do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateAuditLog.discardResultStatement touched)

instance Record Generated.ActualTypes.AuditLog where
    {-# INLINE newRecord #-}
    newRecord = Generated.ActualTypes.AuditLog def def def def def def def  def


instance QueryBuilder.FilterPrimaryKey "audit_log" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (AuditLog') (Id' "audit_log") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "userId" (AuditLog') (Maybe UUID) where
    {-# INLINE setField #-}
    setField newValue record = record { userId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "action" (AuditLog') Text where
    {-# INLINE setField #-}
    setField newValue record = record { action = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "targetType" (AuditLog') Text where
    {-# INLINE setField #-}
    setField newValue record = record { targetType = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "targetId" (AuditLog') (Maybe UUID) where
    {-# INLINE setField #-}
    setField newValue record = record { targetId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance SetField "payload" (AuditLog') (Maybe Data.Aeson.Value) where
    {-# INLINE setField #-}
    setField newValue record = record { payload = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance SetField "ts" (AuditLog') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { ts = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance SetField "meta" (AuditLog') MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (AuditLog') (AuditLog') (Id' "audit_log") (Id' "audit_log") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "userId" (AuditLog') (AuditLog') (Maybe UUID) (Maybe UUID) where
    {-# INLINE updateField #-}
    updateField newValue record = record { userId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "action" (AuditLog') (AuditLog') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { action = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "targetType" (AuditLog') (AuditLog') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { targetType = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "targetId" (AuditLog') (AuditLog') (Maybe UUID) (Maybe UUID) where
    {-# INLINE updateField #-}
    updateField newValue record = record { targetId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance UpdateField "payload" (AuditLog') (AuditLog') (Maybe Data.Aeson.Value) (Maybe Data.Aeson.Value) where
    {-# INLINE updateField #-}
    updateField newValue record = record { payload = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance UpdateField "ts" (AuditLog') (AuditLog') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { ts = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance UpdateField "meta" (AuditLog') (AuditLog') MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (AuditLog') where fieldBit = 1
instance FieldBit "userId" (AuditLog') where fieldBit = 2
instance FieldBit "action" (AuditLog') where fieldBit = 4
instance FieldBit "targetType" (AuditLog') where fieldBit = 8
instance FieldBit "targetId" (AuditLog') where fieldBit = 16
instance FieldBit "payload" (AuditLog') where fieldBit = 32
instance FieldBit "ts" (AuditLog') where fieldBit = 64


