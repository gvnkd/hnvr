-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.Event where
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
import qualified Generated.Statements.RowDecoderEvent
import qualified Generated.Statements.CreateEvent
import qualified Generated.Statements.UpdateEvent
import qualified Generated.Statements.CreateManyEvent
instance InputValue Generated.ActualTypes.Event where inputValue = IHP.ModelSupport.recordToInputValue

instance FromRow Generated.ActualTypes.Event where
    fromRow = do
        id <- field
        cameraId <- field
        ruleId <- field
        ts <- field
        kind <- field
        classId <- field
        trackId <- field
        confidence <- field
        bbox <- field
        thumbnailKey <- field
        segmentTs <- field
        hostId <- field
        payload <- field
        createdAt <- field
        let theRecord = Generated.ActualTypes.Event id cameraId ruleId ts kind classId trackId confidence bbox thumbnailKey segmentTs hostId payload createdAt def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
        pure theRecord

instance FromRowHasql Generated.ActualTypes.Event where
    hasqlRowDecoder = Generated.Statements.RowDecoderEvent.rowDecoder

type instance GetModelName (Event') = "Event"

instance CanCreate Generated.ActualTypes.Event where
    create = createEvent
    createMany = createManyEvent
    createRecordDiscardResult = createRecordDiscardResultEvent

createEvent :: (?modelContext :: ModelContext) => Generated.ActualTypes.Event -> IO Generated.ActualTypes.Event
createEvent model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateEvent.statement touched)

createManyEvent :: (?modelContext :: ModelContext) => [Generated.ActualTypes.Event] -> IO [Generated.ActualTypes.Event]
createManyEvent [] = pure []
createManyEvent models = do
    let pool = ?modelContext.hasqlPool
    let touchedList = List.map (\model -> model.meta.touchedFields) models
    sqlStatementHasql pool models (Generated.Statements.CreateManyEvent.statement touchedList)

createRecordDiscardResultEvent :: (?modelContext :: ModelContext) => Generated.ActualTypes.Event -> IO ()
createRecordDiscardResultEvent model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateEvent.discardResultStatement touched)

instance CanUpdate Generated.ActualTypes.Event where
    updateRecord = updateRecordEvent
    updateRecordDiscardResult = updateRecordDiscardResultEvent

updateRecordEvent :: (?modelContext :: ModelContext) => Generated.ActualTypes.Event -> IO Generated.ActualTypes.Event
updateRecordEvent model = do
    let touched = model.meta.touchedFields
    if touched == 0 then pure model else do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateEvent.statement touched)

updateRecordDiscardResultEvent :: (?modelContext :: ModelContext) => Generated.ActualTypes.Event -> IO ()
updateRecordDiscardResultEvent model = do
    let touched = model.meta.touchedFields
    unless (touched == 0) $ do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateEvent.discardResultStatement touched)

instance Record Generated.ActualTypes.Event where
    {-# INLINE newRecord #-}
    newRecord = Generated.ActualTypes.Event def def def def def def def def def def def def def def  def


instance QueryBuilder.FilterPrimaryKey "events" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (Event') (Id' "events") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "cameraId" (Event') UUID where
    {-# INLINE setField #-}
    setField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "ruleId" (Event') (Maybe UUID) where
    {-# INLINE setField #-}
    setField newValue record = record { ruleId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "ts" (Event') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { ts = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "kind" (Event') EventKind where
    {-# INLINE setField #-}
    setField newValue record = record { kind = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance SetField "classId" (Event') (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { classId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance SetField "trackId" (Event') (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { trackId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance SetField "confidence" (Event') (Maybe Float) where
    {-# INLINE setField #-}
    setField newValue record = record { confidence = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance SetField "bbox" (Event') (Maybe Data.Aeson.Value) where
    {-# INLINE setField #-}
    setField newValue record = record { bbox = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance SetField "thumbnailKey" (Event') (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { thumbnailKey = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 512 } }
instance SetField "segmentTs" (Event') (Maybe UTCTime) where
    {-# INLINE setField #-}
    setField newValue record = record { segmentTs = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1024 } }
instance SetField "hostId" (Event') (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { hostId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2048 } }
instance SetField "payload" (Event') (Maybe Data.Aeson.Value) where
    {-# INLINE setField #-}
    setField newValue record = record { payload = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4096 } }
instance SetField "createdAt" (Event') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8192 } }
instance SetField "meta" (Event') MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (Event') (Event') (Id' "events") (Id' "events") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "cameraId" (Event') (Event') UUID UUID where
    {-# INLINE updateField #-}
    updateField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "ruleId" (Event') (Event') (Maybe UUID) (Maybe UUID) where
    {-# INLINE updateField #-}
    updateField newValue record = record { ruleId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "ts" (Event') (Event') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { ts = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "kind" (Event') (Event') EventKind EventKind where
    {-# INLINE updateField #-}
    updateField newValue record = record { kind = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance UpdateField "classId" (Event') (Event') (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { classId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance UpdateField "trackId" (Event') (Event') (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { trackId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance UpdateField "confidence" (Event') (Event') (Maybe Float) (Maybe Float) where
    {-# INLINE updateField #-}
    updateField newValue record = record { confidence = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance UpdateField "bbox" (Event') (Event') (Maybe Data.Aeson.Value) (Maybe Data.Aeson.Value) where
    {-# INLINE updateField #-}
    updateField newValue record = record { bbox = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance UpdateField "thumbnailKey" (Event') (Event') (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { thumbnailKey = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 512 } }
instance UpdateField "segmentTs" (Event') (Event') (Maybe UTCTime) (Maybe UTCTime) where
    {-# INLINE updateField #-}
    updateField newValue record = record { segmentTs = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1024 } }
instance UpdateField "hostId" (Event') (Event') (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { hostId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2048 } }
instance UpdateField "payload" (Event') (Event') (Maybe Data.Aeson.Value) (Maybe Data.Aeson.Value) where
    {-# INLINE updateField #-}
    updateField newValue record = record { payload = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4096 } }
instance UpdateField "createdAt" (Event') (Event') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8192 } }
instance UpdateField "meta" (Event') (Event') MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (Event') where fieldBit = 1
instance FieldBit "cameraId" (Event') where fieldBit = 2
instance FieldBit "ruleId" (Event') where fieldBit = 4
instance FieldBit "ts" (Event') where fieldBit = 8
instance FieldBit "kind" (Event') where fieldBit = 16
instance FieldBit "classId" (Event') where fieldBit = 32
instance FieldBit "trackId" (Event') where fieldBit = 64
instance FieldBit "confidence" (Event') where fieldBit = 128
instance FieldBit "bbox" (Event') where fieldBit = 256
instance FieldBit "thumbnailKey" (Event') where fieldBit = 512
instance FieldBit "segmentTs" (Event') where fieldBit = 1024
instance FieldBit "hostId" (Event') where fieldBit = 2048
instance FieldBit "payload" (Event') where fieldBit = 4096
instance FieldBit "createdAt" (Event') where fieldBit = 8192


