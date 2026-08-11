-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.Camera where
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
import qualified Generated.Statements.RowDecoderCamera
import qualified Generated.Statements.CreateCamera
import qualified Generated.Statements.UpdateCamera
import qualified Generated.Statements.CreateManyCamera
instance InputValue Generated.ActualTypes.Camera where inputValue = IHP.ModelSupport.recordToInputValue

instance FromRow Generated.ActualTypes.Camera where
    fromRow = do
        id <- field
        slug <- field
        name <- field
        rtspUrl <- field
        rtspTemplate <- field
        rtspTransport <- field
        host <- field
        port <- field
        username <- field
        passwordEnc <- field
        passwordNonce <- field
        codec <- field
        rtspSubUrl <- field
        rtspSubTemplate <- field
        useSubstreamForAnalysis <- field
        substreamCodec <- field
        substreamWidth <- field
        substreamHeight <- field
        recordAudio <- field
        analysisFps <- field
        enabled <- field
        retentionDays <- field
        assignedHost <- field
        manualAssign <- field
        createdAt <- field
        updatedAt <- field
        let theRecord = Generated.ActualTypes.Camera id slug name rtspUrl rtspTemplate rtspTransport host port username passwordEnc passwordNonce codec rtspSubUrl rtspSubTemplate useSubstreamForAnalysis substreamCodec substreamWidth substreamHeight recordAudio analysisFps enabled retentionDays assignedHost manualAssign createdAt updatedAt def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
        pure theRecord

instance FromRowHasql Generated.ActualTypes.Camera where
    hasqlRowDecoder = Generated.Statements.RowDecoderCamera.rowDecoder

type instance GetModelName (Camera') = "Camera"

instance CanCreate Generated.ActualTypes.Camera where
    create = createCamera
    createMany = createManyCamera
    createRecordDiscardResult = createRecordDiscardResultCamera

createCamera :: (?modelContext :: ModelContext) => Generated.ActualTypes.Camera -> IO Generated.ActualTypes.Camera
createCamera model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateCamera.statement touched)

createManyCamera :: (?modelContext :: ModelContext) => [Generated.ActualTypes.Camera] -> IO [Generated.ActualTypes.Camera]
createManyCamera [] = pure []
createManyCamera models = do
    let pool = ?modelContext.hasqlPool
    let touchedList = List.map (\model -> model.meta.touchedFields) models
    sqlStatementHasql pool models (Generated.Statements.CreateManyCamera.statement touchedList)

createRecordDiscardResultCamera :: (?modelContext :: ModelContext) => Generated.ActualTypes.Camera -> IO ()
createRecordDiscardResultCamera model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateCamera.discardResultStatement touched)

instance CanUpdate Generated.ActualTypes.Camera where
    updateRecord = updateRecordCamera
    updateRecordDiscardResult = updateRecordDiscardResultCamera

updateRecordCamera :: (?modelContext :: ModelContext) => Generated.ActualTypes.Camera -> IO Generated.ActualTypes.Camera
updateRecordCamera model = do
    let touched = model.meta.touchedFields
    if touched == 0 then pure model else do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateCamera.statement touched)

updateRecordDiscardResultCamera :: (?modelContext :: ModelContext) => Generated.ActualTypes.Camera -> IO ()
updateRecordDiscardResultCamera model = do
    let touched = model.meta.touchedFields
    unless (touched == 0) $ do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateCamera.discardResultStatement touched)

instance Record Generated.ActualTypes.Camera where
    {-# INLINE newRecord #-}
    newRecord = Generated.ActualTypes.Camera def def def def def "tcp" def def def def def def def def True def def def False def True def def False def def  def


instance QueryBuilder.FilterPrimaryKey "cameras" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (Camera') (Id' "cameras") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "slug" (Camera') Text where
    {-# INLINE setField #-}
    setField newValue record = record { slug = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "name" (Camera') Text where
    {-# INLINE setField #-}
    setField newValue record = record { name = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "rtspUrl" (Camera') Text where
    {-# INLINE setField #-}
    setField newValue record = record { rtspUrl = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "rtspTemplate" (Camera') (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { rtspTemplate = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance SetField "rtspTransport" (Camera') Text where
    {-# INLINE setField #-}
    setField newValue record = record { rtspTransport = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance SetField "host" (Camera') (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { host = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance SetField "port" (Camera') Int where
    {-# INLINE setField #-}
    setField newValue record = record { port = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance SetField "username" (Camera') (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { username = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance SetField "passwordEnc" (Camera') (Maybe (Binary ByteString)) where
    {-# INLINE setField #-}
    setField newValue record = record { passwordEnc = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 512 } }
instance SetField "passwordNonce" (Camera') (Maybe (Binary ByteString)) where
    {-# INLINE setField #-}
    setField newValue record = record { passwordNonce = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1024 } }
instance SetField "codec" (Camera') CodecKind where
    {-# INLINE setField #-}
    setField newValue record = record { codec = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2048 } }
instance SetField "rtspSubUrl" (Camera') (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { rtspSubUrl = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4096 } }
instance SetField "rtspSubTemplate" (Camera') (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { rtspSubTemplate = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8192 } }
instance SetField "useSubstreamForAnalysis" (Camera') Bool where
    {-# INLINE setField #-}
    setField newValue record = record { useSubstreamForAnalysis = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16384 } }
instance SetField "substreamCodec" (Camera') CodecKind where
    {-# INLINE setField #-}
    setField newValue record = record { substreamCodec = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32768 } }
instance SetField "substreamWidth" (Camera') (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { substreamWidth = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 65536 } }
instance SetField "substreamHeight" (Camera') (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { substreamHeight = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 131072 } }
instance SetField "recordAudio" (Camera') Bool where
    {-# INLINE setField #-}
    setField newValue record = record { recordAudio = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 262144 } }
instance SetField "analysisFps" (Camera') Int where
    {-# INLINE setField #-}
    setField newValue record = record { analysisFps = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 524288 } }
instance SetField "enabled" (Camera') Bool where
    {-# INLINE setField #-}
    setField newValue record = record { enabled = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1048576 } }
instance SetField "retentionDays" (Camera') Int where
    {-# INLINE setField #-}
    setField newValue record = record { retentionDays = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2097152 } }
instance SetField "assignedHost" (Camera') (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { assignedHost = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4194304 } }
instance SetField "manualAssign" (Camera') Bool where
    {-# INLINE setField #-}
    setField newValue record = record { manualAssign = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8388608 } }
instance SetField "createdAt" (Camera') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16777216 } }
instance SetField "updatedAt" (Camera') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { updatedAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 33554432 } }
instance SetField "meta" (Camera') MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (Camera') (Camera') (Id' "cameras") (Id' "cameras") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "slug" (Camera') (Camera') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { slug = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "name" (Camera') (Camera') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { name = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "rtspUrl" (Camera') (Camera') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { rtspUrl = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "rtspTemplate" (Camera') (Camera') (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { rtspTemplate = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance UpdateField "rtspTransport" (Camera') (Camera') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { rtspTransport = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance UpdateField "host" (Camera') (Camera') (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { host = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance UpdateField "port" (Camera') (Camera') Int Int where
    {-# INLINE updateField #-}
    updateField newValue record = record { port = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance UpdateField "username" (Camera') (Camera') (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { username = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance UpdateField "passwordEnc" (Camera') (Camera') (Maybe (Binary ByteString)) (Maybe (Binary ByteString)) where
    {-# INLINE updateField #-}
    updateField newValue record = record { passwordEnc = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 512 } }
instance UpdateField "passwordNonce" (Camera') (Camera') (Maybe (Binary ByteString)) (Maybe (Binary ByteString)) where
    {-# INLINE updateField #-}
    updateField newValue record = record { passwordNonce = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1024 } }
instance UpdateField "codec" (Camera') (Camera') CodecKind CodecKind where
    {-# INLINE updateField #-}
    updateField newValue record = record { codec = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2048 } }
instance UpdateField "rtspSubUrl" (Camera') (Camera') (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { rtspSubUrl = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4096 } }
instance UpdateField "rtspSubTemplate" (Camera') (Camera') (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { rtspSubTemplate = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8192 } }
instance UpdateField "useSubstreamForAnalysis" (Camera') (Camera') Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { useSubstreamForAnalysis = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16384 } }
instance UpdateField "substreamCodec" (Camera') (Camera') CodecKind CodecKind where
    {-# INLINE updateField #-}
    updateField newValue record = record { substreamCodec = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32768 } }
instance UpdateField "substreamWidth" (Camera') (Camera') (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { substreamWidth = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 65536 } }
instance UpdateField "substreamHeight" (Camera') (Camera') (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { substreamHeight = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 131072 } }
instance UpdateField "recordAudio" (Camera') (Camera') Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { recordAudio = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 262144 } }
instance UpdateField "analysisFps" (Camera') (Camera') Int Int where
    {-# INLINE updateField #-}
    updateField newValue record = record { analysisFps = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 524288 } }
instance UpdateField "enabled" (Camera') (Camera') Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { enabled = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1048576 } }
instance UpdateField "retentionDays" (Camera') (Camera') Int Int where
    {-# INLINE updateField #-}
    updateField newValue record = record { retentionDays = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2097152 } }
instance UpdateField "assignedHost" (Camera') (Camera') (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { assignedHost = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4194304 } }
instance UpdateField "manualAssign" (Camera') (Camera') Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { manualAssign = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8388608 } }
instance UpdateField "createdAt" (Camera') (Camera') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16777216 } }
instance UpdateField "updatedAt" (Camera') (Camera') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { updatedAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 33554432 } }
instance UpdateField "meta" (Camera') (Camera') MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (Camera') where fieldBit = 1
instance FieldBit "slug" (Camera') where fieldBit = 2
instance FieldBit "name" (Camera') where fieldBit = 4
instance FieldBit "rtspUrl" (Camera') where fieldBit = 8
instance FieldBit "rtspTemplate" (Camera') where fieldBit = 16
instance FieldBit "rtspTransport" (Camera') where fieldBit = 32
instance FieldBit "host" (Camera') where fieldBit = 64
instance FieldBit "port" (Camera') where fieldBit = 128
instance FieldBit "username" (Camera') where fieldBit = 256
instance FieldBit "passwordEnc" (Camera') where fieldBit = 512
instance FieldBit "passwordNonce" (Camera') where fieldBit = 1024
instance FieldBit "codec" (Camera') where fieldBit = 2048
instance FieldBit "rtspSubUrl" (Camera') where fieldBit = 4096
instance FieldBit "rtspSubTemplate" (Camera') where fieldBit = 8192
instance FieldBit "useSubstreamForAnalysis" (Camera') where fieldBit = 16384
instance FieldBit "substreamCodec" (Camera') where fieldBit = 32768
instance FieldBit "substreamWidth" (Camera') where fieldBit = 65536
instance FieldBit "substreamHeight" (Camera') where fieldBit = 131072
instance FieldBit "recordAudio" (Camera') where fieldBit = 262144
instance FieldBit "analysisFps" (Camera') where fieldBit = 524288
instance FieldBit "enabled" (Camera') where fieldBit = 1048576
instance FieldBit "retentionDays" (Camera') where fieldBit = 2097152
instance FieldBit "assignedHost" (Camera') where fieldBit = 4194304
instance FieldBit "manualAssign" (Camera') where fieldBit = 8388608
instance FieldBit "createdAt" (Camera') where fieldBit = 16777216
instance FieldBit "updatedAt" (Camera') where fieldBit = 33554432


