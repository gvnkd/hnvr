-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.PtzPreset where
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
import qualified Generated.Statements.RowDecoderPtzPreset
import qualified Generated.Statements.CreatePtzPreset
import qualified Generated.Statements.UpdatePtzPreset
import qualified Generated.Statements.CreateManyPtzPreset
instance InputValue Generated.ActualTypes.PtzPreset where inputValue = IHP.ModelSupport.recordToInputValue

instance FromRow Generated.ActualTypes.PtzPreset where
    fromRow = do
        id <- field
        cameraId <- field
        name <- field
        onvifToken <- field
        pantiltX <- field
        pantiltY <- field
        zoom <- field
        isHome <- field
        createdAt <- field
        let theRecord = Generated.ActualTypes.PtzPreset id cameraId name onvifToken pantiltX pantiltY zoom isHome createdAt (QueryBuilder.filterWhere (#ptzHomePresetId, Just id) (QueryBuilder.query @Camera)) def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
        pure theRecord

instance FromRowHasql Generated.ActualTypes.PtzPreset where
    hasqlRowDecoder = Generated.Statements.RowDecoderPtzPreset.rowDecoder

type instance GetModelName (PtzPreset' _) = "PtzPreset"

instance CanCreate Generated.ActualTypes.PtzPreset where
    create = createPtzPreset
    createMany = createManyPtzPreset
    createRecordDiscardResult = createRecordDiscardResultPtzPreset

createPtzPreset :: (?modelContext :: ModelContext) => Generated.ActualTypes.PtzPreset -> IO Generated.ActualTypes.PtzPreset
createPtzPreset model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreatePtzPreset.statement touched)

createManyPtzPreset :: (?modelContext :: ModelContext) => [Generated.ActualTypes.PtzPreset] -> IO [Generated.ActualTypes.PtzPreset]
createManyPtzPreset [] = pure []
createManyPtzPreset models = do
    let pool = ?modelContext.hasqlPool
    let touchedList = List.map (\model -> model.meta.touchedFields) models
    sqlStatementHasql pool models (Generated.Statements.CreateManyPtzPreset.statement touchedList)

createRecordDiscardResultPtzPreset :: (?modelContext :: ModelContext) => Generated.ActualTypes.PtzPreset -> IO ()
createRecordDiscardResultPtzPreset model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreatePtzPreset.discardResultStatement touched)

instance CanUpdate Generated.ActualTypes.PtzPreset where
    updateRecord = updateRecordPtzPreset
    updateRecordDiscardResult = updateRecordDiscardResultPtzPreset

updateRecordPtzPreset :: (?modelContext :: ModelContext) => Generated.ActualTypes.PtzPreset -> IO Generated.ActualTypes.PtzPreset
updateRecordPtzPreset model = do
    let touched = model.meta.touchedFields
    if touched == 0 then pure model else do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdatePtzPreset.statement touched)

updateRecordDiscardResultPtzPreset :: (?modelContext :: ModelContext) => Generated.ActualTypes.PtzPreset -> IO ()
updateRecordDiscardResultPtzPreset model = do
    let touched = model.meta.touchedFields
    unless (touched == 0) $ do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdatePtzPreset.discardResultStatement touched)

instance Record Generated.ActualTypes.PtzPreset where
    {-# INLINE newRecord #-}
    newRecord = Generated.ActualTypes.PtzPreset def def def def def def def False def def def


instance QueryBuilder.FilterPrimaryKey "ptz_presets" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (PtzPreset' cameras) (Id' "ptz_presets") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "cameraId" (PtzPreset' cameras) UUID where
    {-# INLINE setField #-}
    setField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "name" (PtzPreset' cameras) Text where
    {-# INLINE setField #-}
    setField newValue record = record { name = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "onvifToken" (PtzPreset' cameras) (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { onvifToken = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "pantiltX" (PtzPreset' cameras) (Maybe Float) where
    {-# INLINE setField #-}
    setField newValue record = record { pantiltX = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance SetField "pantiltY" (PtzPreset' cameras) (Maybe Float) where
    {-# INLINE setField #-}
    setField newValue record = record { pantiltY = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance SetField "zoom" (PtzPreset' cameras) (Maybe Float) where
    {-# INLINE setField #-}
    setField newValue record = record { zoom = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance SetField "isHome" (PtzPreset' cameras) Bool where
    {-# INLINE setField #-}
    setField newValue record = record { isHome = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance SetField "createdAt" (PtzPreset' cameras) UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance SetField "cameras" (PtzPreset' cameras) cameras where
    {-# INLINE setField #-}
    setField newValue record = record { cameras = newValue }
instance SetField "meta" (PtzPreset' cameras) MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (PtzPreset' cameras) (PtzPreset' cameras) (Id' "ptz_presets") (Id' "ptz_presets") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "cameraId" (PtzPreset' cameras) (PtzPreset' cameras) UUID UUID where
    {-# INLINE updateField #-}
    updateField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "name" (PtzPreset' cameras) (PtzPreset' cameras) Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { name = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "onvifToken" (PtzPreset' cameras) (PtzPreset' cameras) (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { onvifToken = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "pantiltX" (PtzPreset' cameras) (PtzPreset' cameras) (Maybe Float) (Maybe Float) where
    {-# INLINE updateField #-}
    updateField newValue record = record { pantiltX = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance UpdateField "pantiltY" (PtzPreset' cameras) (PtzPreset' cameras) (Maybe Float) (Maybe Float) where
    {-# INLINE updateField #-}
    updateField newValue record = record { pantiltY = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance UpdateField "zoom" (PtzPreset' cameras) (PtzPreset' cameras) (Maybe Float) (Maybe Float) where
    {-# INLINE updateField #-}
    updateField newValue record = record { zoom = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance UpdateField "isHome" (PtzPreset' cameras) (PtzPreset' cameras) Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { isHome = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance UpdateField "createdAt" (PtzPreset' cameras) (PtzPreset' cameras) UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance UpdateField "cameras" (PtzPreset' cameras) (PtzPreset' cameras') cameras cameras' where
    {-# INLINE updateField #-}
    updateField newValue (PtzPreset id cameraId name onvifToken pantiltX pantiltY zoom isHome createdAt cameras meta) = PtzPreset id cameraId name onvifToken pantiltX pantiltY zoom isHome createdAt newValue meta
instance UpdateField "meta" (PtzPreset' cameras) (PtzPreset' cameras) MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (PtzPreset' cameras) where fieldBit = 1
instance FieldBit "cameraId" (PtzPreset' cameras) where fieldBit = 2
instance FieldBit "name" (PtzPreset' cameras) where fieldBit = 4
instance FieldBit "onvifToken" (PtzPreset' cameras) where fieldBit = 8
instance FieldBit "pantiltX" (PtzPreset' cameras) where fieldBit = 16
instance FieldBit "pantiltY" (PtzPreset' cameras) where fieldBit = 32
instance FieldBit "zoom" (PtzPreset' cameras) where fieldBit = 64
instance FieldBit "isHome" (PtzPreset' cameras) where fieldBit = 128
instance FieldBit "createdAt" (PtzPreset' cameras) where fieldBit = 256


