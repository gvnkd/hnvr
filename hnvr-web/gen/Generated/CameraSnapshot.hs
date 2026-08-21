-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.CameraSnapshot where
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
import qualified Generated.Statements.RowDecoderCameraSnapshot
import qualified Generated.Statements.CreateCameraSnapshot
import qualified Generated.Statements.UpdateCameraSnapshot
import qualified Generated.Statements.CreateManyCameraSnapshot
instance InputValue Generated.ActualTypes.CameraSnapshot where inputValue = IHP.ModelSupport.recordToInputValue

instance FromRow Generated.ActualTypes.CameraSnapshot where
    fromRow = do
        id <- field
        cameraId <- field
        ts <- field
        objectKey <- field
        bytes <- field
        createdAt <- field
        let theRecord = Generated.ActualTypes.CameraSnapshot id cameraId ts objectKey bytes createdAt def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
        pure theRecord

instance FromRowHasql Generated.ActualTypes.CameraSnapshot where
    hasqlRowDecoder = Generated.Statements.RowDecoderCameraSnapshot.rowDecoder

type instance GetModelName (CameraSnapshot') = "CameraSnapshot"

instance CanCreate Generated.ActualTypes.CameraSnapshot where
    create = createCameraSnapshot
    createMany = createManyCameraSnapshot
    createRecordDiscardResult = createRecordDiscardResultCameraSnapshot

createCameraSnapshot :: (?modelContext :: ModelContext) => Generated.ActualTypes.CameraSnapshot -> IO Generated.ActualTypes.CameraSnapshot
createCameraSnapshot model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateCameraSnapshot.statement touched)

createManyCameraSnapshot :: (?modelContext :: ModelContext) => [Generated.ActualTypes.CameraSnapshot] -> IO [Generated.ActualTypes.CameraSnapshot]
createManyCameraSnapshot [] = pure []
createManyCameraSnapshot models = do
    let pool = ?modelContext.hasqlPool
    let touchedList = List.map (\model -> model.meta.touchedFields) models
    sqlStatementHasql pool models (Generated.Statements.CreateManyCameraSnapshot.statement touchedList)

createRecordDiscardResultCameraSnapshot :: (?modelContext :: ModelContext) => Generated.ActualTypes.CameraSnapshot -> IO ()
createRecordDiscardResultCameraSnapshot model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateCameraSnapshot.discardResultStatement touched)

instance CanUpdate Generated.ActualTypes.CameraSnapshot where
    updateRecord = updateRecordCameraSnapshot
    updateRecordDiscardResult = updateRecordDiscardResultCameraSnapshot

updateRecordCameraSnapshot :: (?modelContext :: ModelContext) => Generated.ActualTypes.CameraSnapshot -> IO Generated.ActualTypes.CameraSnapshot
updateRecordCameraSnapshot model = do
    let touched = model.meta.touchedFields
    if touched == 0 then pure model else do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateCameraSnapshot.statement touched)

updateRecordDiscardResultCameraSnapshot :: (?modelContext :: ModelContext) => Generated.ActualTypes.CameraSnapshot -> IO ()
updateRecordDiscardResultCameraSnapshot model = do
    let touched = model.meta.touchedFields
    unless (touched == 0) $ do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateCameraSnapshot.discardResultStatement touched)

instance Record Generated.ActualTypes.CameraSnapshot where
    {-# INLINE newRecord #-}
    newRecord = Generated.ActualTypes.CameraSnapshot def def def def def def  def


instance QueryBuilder.FilterPrimaryKey "camera_snapshots" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (CameraSnapshot') (Id' "camera_snapshots") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "cameraId" (CameraSnapshot') UUID where
    {-# INLINE setField #-}
    setField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "ts" (CameraSnapshot') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { ts = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "objectKey" (CameraSnapshot') Text where
    {-# INLINE setField #-}
    setField newValue record = record { objectKey = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "bytes" (CameraSnapshot') Integer where
    {-# INLINE setField #-}
    setField newValue record = record { bytes = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance SetField "createdAt" (CameraSnapshot') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance SetField "meta" (CameraSnapshot') MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (CameraSnapshot') (CameraSnapshot') (Id' "camera_snapshots") (Id' "camera_snapshots") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "cameraId" (CameraSnapshot') (CameraSnapshot') UUID UUID where
    {-# INLINE updateField #-}
    updateField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "ts" (CameraSnapshot') (CameraSnapshot') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { ts = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "objectKey" (CameraSnapshot') (CameraSnapshot') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { objectKey = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "bytes" (CameraSnapshot') (CameraSnapshot') Integer Integer where
    {-# INLINE updateField #-}
    updateField newValue record = record { bytes = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance UpdateField "createdAt" (CameraSnapshot') (CameraSnapshot') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance UpdateField "meta" (CameraSnapshot') (CameraSnapshot') MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (CameraSnapshot') where fieldBit = 1
instance FieldBit "cameraId" (CameraSnapshot') where fieldBit = 2
instance FieldBit "ts" (CameraSnapshot') where fieldBit = 4
instance FieldBit "objectKey" (CameraSnapshot') where fieldBit = 8
instance FieldBit "bytes" (CameraSnapshot') where fieldBit = 16
instance FieldBit "createdAt" (CameraSnapshot') where fieldBit = 32


