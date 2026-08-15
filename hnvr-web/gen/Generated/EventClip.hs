-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.EventClip where
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
import qualified Generated.Statements.RowDecoderEventClip
import qualified Generated.Statements.CreateEventClip
import qualified Generated.Statements.UpdateEventClip
import qualified Generated.Statements.CreateManyEventClip
instance InputValue Generated.ActualTypes.EventClip where inputValue = IHP.ModelSupport.recordToInputValue

instance FromRow Generated.ActualTypes.EventClip where
    fromRow = do
        id <- field
        cameraId <- field
        ruleId <- field
        startedAt <- field
        durationSec <- field
        objectPrefix <- field
        retentionHours <- field
        pendingDeleteAt <- field
        createdAt <- field
        let theRecord = Generated.ActualTypes.EventClip id cameraId ruleId startedAt durationSec objectPrefix retentionHours pendingDeleteAt createdAt def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
        pure theRecord

instance FromRowHasql Generated.ActualTypes.EventClip where
    hasqlRowDecoder = Generated.Statements.RowDecoderEventClip.rowDecoder

type instance GetModelName (EventClip') = "EventClip"

instance CanCreate Generated.ActualTypes.EventClip where
    create = createEventClip
    createMany = createManyEventClip
    createRecordDiscardResult = createRecordDiscardResultEventClip

createEventClip :: (?modelContext :: ModelContext) => Generated.ActualTypes.EventClip -> IO Generated.ActualTypes.EventClip
createEventClip model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateEventClip.statement touched)

createManyEventClip :: (?modelContext :: ModelContext) => [Generated.ActualTypes.EventClip] -> IO [Generated.ActualTypes.EventClip]
createManyEventClip [] = pure []
createManyEventClip models = do
    let pool = ?modelContext.hasqlPool
    let touchedList = List.map (\model -> model.meta.touchedFields) models
    sqlStatementHasql pool models (Generated.Statements.CreateManyEventClip.statement touchedList)

createRecordDiscardResultEventClip :: (?modelContext :: ModelContext) => Generated.ActualTypes.EventClip -> IO ()
createRecordDiscardResultEventClip model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateEventClip.discardResultStatement touched)

instance CanUpdate Generated.ActualTypes.EventClip where
    updateRecord = updateRecordEventClip
    updateRecordDiscardResult = updateRecordDiscardResultEventClip

updateRecordEventClip :: (?modelContext :: ModelContext) => Generated.ActualTypes.EventClip -> IO Generated.ActualTypes.EventClip
updateRecordEventClip model = do
    let touched = model.meta.touchedFields
    if touched == 0 then pure model else do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateEventClip.statement touched)

updateRecordDiscardResultEventClip :: (?modelContext :: ModelContext) => Generated.ActualTypes.EventClip -> IO ()
updateRecordDiscardResultEventClip model = do
    let touched = model.meta.touchedFields
    unless (touched == 0) $ do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateEventClip.discardResultStatement touched)

instance Record Generated.ActualTypes.EventClip where
    {-# INLINE newRecord #-}
    newRecord = Generated.ActualTypes.EventClip def def def def def def def def def  def


instance QueryBuilder.FilterPrimaryKey "event_clips" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (EventClip') (Id' "event_clips") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "cameraId" (EventClip') UUID where
    {-# INLINE setField #-}
    setField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "ruleId" (EventClip') (Maybe UUID) where
    {-# INLINE setField #-}
    setField newValue record = record { ruleId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "startedAt" (EventClip') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { startedAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "durationSec" (EventClip') Int where
    {-# INLINE setField #-}
    setField newValue record = record { durationSec = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance SetField "objectPrefix" (EventClip') Text where
    {-# INLINE setField #-}
    setField newValue record = record { objectPrefix = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance SetField "retentionHours" (EventClip') Int where
    {-# INLINE setField #-}
    setField newValue record = record { retentionHours = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance SetField "pendingDeleteAt" (EventClip') (Maybe UTCTime) where
    {-# INLINE setField #-}
    setField newValue record = record { pendingDeleteAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance SetField "createdAt" (EventClip') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance SetField "meta" (EventClip') MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (EventClip') (EventClip') (Id' "event_clips") (Id' "event_clips") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "cameraId" (EventClip') (EventClip') UUID UUID where
    {-# INLINE updateField #-}
    updateField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "ruleId" (EventClip') (EventClip') (Maybe UUID) (Maybe UUID) where
    {-# INLINE updateField #-}
    updateField newValue record = record { ruleId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "startedAt" (EventClip') (EventClip') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { startedAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "durationSec" (EventClip') (EventClip') Int Int where
    {-# INLINE updateField #-}
    updateField newValue record = record { durationSec = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance UpdateField "objectPrefix" (EventClip') (EventClip') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { objectPrefix = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance UpdateField "retentionHours" (EventClip') (EventClip') Int Int where
    {-# INLINE updateField #-}
    updateField newValue record = record { retentionHours = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance UpdateField "pendingDeleteAt" (EventClip') (EventClip') (Maybe UTCTime) (Maybe UTCTime) where
    {-# INLINE updateField #-}
    updateField newValue record = record { pendingDeleteAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance UpdateField "createdAt" (EventClip') (EventClip') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance UpdateField "meta" (EventClip') (EventClip') MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (EventClip') where fieldBit = 1
instance FieldBit "cameraId" (EventClip') where fieldBit = 2
instance FieldBit "ruleId" (EventClip') where fieldBit = 4
instance FieldBit "startedAt" (EventClip') where fieldBit = 8
instance FieldBit "durationSec" (EventClip') where fieldBit = 16
instance FieldBit "objectPrefix" (EventClip') where fieldBit = 32
instance FieldBit "retentionHours" (EventClip') where fieldBit = 64
instance FieldBit "pendingDeleteAt" (EventClip') where fieldBit = 128
instance FieldBit "createdAt" (EventClip') where fieldBit = 256


