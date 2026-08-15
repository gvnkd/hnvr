-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.EventClipEvent where
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
import qualified Generated.Statements.RowDecoderEventClipEvent
import qualified Generated.Statements.CreateEventClipEvent
import qualified Generated.Statements.UpdateEventClipEvent
import qualified Generated.Statements.CreateManyEventClipEvent
instance InputValue Generated.ActualTypes.EventClipEvent where inputValue = IHP.ModelSupport.recordToInputValue

instance FromRow Generated.ActualTypes.EventClipEvent where
    fromRow = do
        id <- field
        clipId <- field
        eventId <- field
        createdAt <- field
        let theRecord = Generated.ActualTypes.EventClipEvent id clipId eventId createdAt def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
        pure theRecord

instance FromRowHasql Generated.ActualTypes.EventClipEvent where
    hasqlRowDecoder = Generated.Statements.RowDecoderEventClipEvent.rowDecoder

type instance GetModelName (EventClipEvent') = "EventClipEvent"

instance CanCreate Generated.ActualTypes.EventClipEvent where
    create = createEventClipEvent
    createMany = createManyEventClipEvent
    createRecordDiscardResult = createRecordDiscardResultEventClipEvent

createEventClipEvent :: (?modelContext :: ModelContext) => Generated.ActualTypes.EventClipEvent -> IO Generated.ActualTypes.EventClipEvent
createEventClipEvent model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateEventClipEvent.statement touched)

createManyEventClipEvent :: (?modelContext :: ModelContext) => [Generated.ActualTypes.EventClipEvent] -> IO [Generated.ActualTypes.EventClipEvent]
createManyEventClipEvent [] = pure []
createManyEventClipEvent models = do
    let pool = ?modelContext.hasqlPool
    let touchedList = List.map (\model -> model.meta.touchedFields) models
    sqlStatementHasql pool models (Generated.Statements.CreateManyEventClipEvent.statement touchedList)

createRecordDiscardResultEventClipEvent :: (?modelContext :: ModelContext) => Generated.ActualTypes.EventClipEvent -> IO ()
createRecordDiscardResultEventClipEvent model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateEventClipEvent.discardResultStatement touched)

instance CanUpdate Generated.ActualTypes.EventClipEvent where
    updateRecord = updateRecordEventClipEvent
    updateRecordDiscardResult = updateRecordDiscardResultEventClipEvent

updateRecordEventClipEvent :: (?modelContext :: ModelContext) => Generated.ActualTypes.EventClipEvent -> IO Generated.ActualTypes.EventClipEvent
updateRecordEventClipEvent model = do
    let touched = model.meta.touchedFields
    if touched == 0 then pure model else do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateEventClipEvent.statement touched)

updateRecordDiscardResultEventClipEvent :: (?modelContext :: ModelContext) => Generated.ActualTypes.EventClipEvent -> IO ()
updateRecordDiscardResultEventClipEvent model = do
    let touched = model.meta.touchedFields
    unless (touched == 0) $ do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateEventClipEvent.discardResultStatement touched)

instance Record Generated.ActualTypes.EventClipEvent where
    {-# INLINE newRecord #-}
    newRecord = Generated.ActualTypes.EventClipEvent def def def def  def


instance QueryBuilder.FilterPrimaryKey "event_clip_events" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (EventClipEvent') (Id' "event_clip_events") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "clipId" (EventClipEvent') UUID where
    {-# INLINE setField #-}
    setField newValue record = record { clipId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "eventId" (EventClipEvent') UUID where
    {-# INLINE setField #-}
    setField newValue record = record { eventId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "createdAt" (EventClipEvent') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "meta" (EventClipEvent') MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (EventClipEvent') (EventClipEvent') (Id' "event_clip_events") (Id' "event_clip_events") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "clipId" (EventClipEvent') (EventClipEvent') UUID UUID where
    {-# INLINE updateField #-}
    updateField newValue record = record { clipId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "eventId" (EventClipEvent') (EventClipEvent') UUID UUID where
    {-# INLINE updateField #-}
    updateField newValue record = record { eventId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "createdAt" (EventClipEvent') (EventClipEvent') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "meta" (EventClipEvent') (EventClipEvent') MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (EventClipEvent') where fieldBit = 1
instance FieldBit "clipId" (EventClipEvent') where fieldBit = 2
instance FieldBit "eventId" (EventClipEvent') where fieldBit = 4
instance FieldBit "createdAt" (EventClipEvent') where fieldBit = 8


