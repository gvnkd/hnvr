-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.Segment where
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
import qualified Generated.Statements.RowDecoderSegment
import qualified Generated.Statements.CreateSegment
import qualified Generated.Statements.UpdateSegment
import qualified Generated.Statements.CreateManySegment
instance InputValue Generated.ActualTypes.Segment where inputValue = IHP.ModelSupport.recordToInputValue

instance FromRow Generated.ActualTypes.Segment where
    fromRow = do
        id <- field
        cameraId <- field
        startTs <- field
        endTs <- field
        hostId <- field
        objectKey <- field
        bytes <- field
        sha256 <- field
        hasAudio <- field
        pendingDeleteAt <- field
        createdAt <- field
        let theRecord = Generated.ActualTypes.Segment id cameraId startTs endTs hostId objectKey bytes sha256 hasAudio pendingDeleteAt createdAt def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
        pure theRecord

instance FromRowHasql Generated.ActualTypes.Segment where
    hasqlRowDecoder = Generated.Statements.RowDecoderSegment.rowDecoder

type instance GetModelName (Segment') = "Segment"

instance CanCreate Generated.ActualTypes.Segment where
    create = createSegment
    createMany = createManySegment
    createRecordDiscardResult = createRecordDiscardResultSegment

createSegment :: (?modelContext :: ModelContext) => Generated.ActualTypes.Segment -> IO Generated.ActualTypes.Segment
createSegment model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateSegment.statement touched)

createManySegment :: (?modelContext :: ModelContext) => [Generated.ActualTypes.Segment] -> IO [Generated.ActualTypes.Segment]
createManySegment [] = pure []
createManySegment models = do
    let pool = ?modelContext.hasqlPool
    let touchedList = List.map (\model -> model.meta.touchedFields) models
    sqlStatementHasql pool models (Generated.Statements.CreateManySegment.statement touchedList)

createRecordDiscardResultSegment :: (?modelContext :: ModelContext) => Generated.ActualTypes.Segment -> IO ()
createRecordDiscardResultSegment model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateSegment.discardResultStatement touched)

instance CanUpdate Generated.ActualTypes.Segment where
    updateRecord = updateRecordSegment
    updateRecordDiscardResult = updateRecordDiscardResultSegment

updateRecordSegment :: (?modelContext :: ModelContext) => Generated.ActualTypes.Segment -> IO Generated.ActualTypes.Segment
updateRecordSegment model = do
    let touched = model.meta.touchedFields
    if touched == 0 then pure model else do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateSegment.statement touched)

updateRecordDiscardResultSegment :: (?modelContext :: ModelContext) => Generated.ActualTypes.Segment -> IO ()
updateRecordDiscardResultSegment model = do
    let touched = model.meta.touchedFields
    unless (touched == 0) $ do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateSegment.discardResultStatement touched)

instance Record Generated.ActualTypes.Segment where
    {-# INLINE newRecord #-}
    newRecord = Generated.ActualTypes.Segment def def def def def def def def False def def  def


instance QueryBuilder.FilterPrimaryKey "segments" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (Segment') (Id' "segments") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "cameraId" (Segment') UUID where
    {-# INLINE setField #-}
    setField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "startTs" (Segment') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { startTs = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "endTs" (Segment') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { endTs = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "hostId" (Segment') (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { hostId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance SetField "objectKey" (Segment') Text where
    {-# INLINE setField #-}
    setField newValue record = record { objectKey = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance SetField "bytes" (Segment') Integer where
    {-# INLINE setField #-}
    setField newValue record = record { bytes = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance SetField "sha256" (Segment') Text where
    {-# INLINE setField #-}
    setField newValue record = record { sha256 = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance SetField "hasAudio" (Segment') Bool where
    {-# INLINE setField #-}
    setField newValue record = record { hasAudio = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance SetField "pendingDeleteAt" (Segment') (Maybe UTCTime) where
    {-# INLINE setField #-}
    setField newValue record = record { pendingDeleteAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 512 } }
instance SetField "createdAt" (Segment') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1024 } }
instance SetField "meta" (Segment') MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (Segment') (Segment') (Id' "segments") (Id' "segments") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "cameraId" (Segment') (Segment') UUID UUID where
    {-# INLINE updateField #-}
    updateField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "startTs" (Segment') (Segment') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { startTs = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "endTs" (Segment') (Segment') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { endTs = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "hostId" (Segment') (Segment') (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { hostId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance UpdateField "objectKey" (Segment') (Segment') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { objectKey = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance UpdateField "bytes" (Segment') (Segment') Integer Integer where
    {-# INLINE updateField #-}
    updateField newValue record = record { bytes = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance UpdateField "sha256" (Segment') (Segment') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { sha256 = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance UpdateField "hasAudio" (Segment') (Segment') Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { hasAudio = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance UpdateField "pendingDeleteAt" (Segment') (Segment') (Maybe UTCTime) (Maybe UTCTime) where
    {-# INLINE updateField #-}
    updateField newValue record = record { pendingDeleteAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 512 } }
instance UpdateField "createdAt" (Segment') (Segment') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1024 } }
instance UpdateField "meta" (Segment') (Segment') MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (Segment') where fieldBit = 1
instance FieldBit "cameraId" (Segment') where fieldBit = 2
instance FieldBit "startTs" (Segment') where fieldBit = 4
instance FieldBit "endTs" (Segment') where fieldBit = 8
instance FieldBit "hostId" (Segment') where fieldBit = 16
instance FieldBit "objectKey" (Segment') where fieldBit = 32
instance FieldBit "bytes" (Segment') where fieldBit = 64
instance FieldBit "sha256" (Segment') where fieldBit = 128
instance FieldBit "hasAudio" (Segment') where fieldBit = 256
instance FieldBit "pendingDeleteAt" (Segment') where fieldBit = 512
instance FieldBit "createdAt" (Segment') where fieldBit = 1024


