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
        rtspTransport <- field
        host <- field
        username <- field
        passwordEnc <- field
        passwordNonce <- field
        codec <- field
        rtspSubUrl <- field
        useSubstreamForAnalysis <- field
        substreamCodec <- field
        substreamWidth <- field
        substreamHeight <- field
        recordAudio <- field
        analysisFps <- field
        modelName <- field
        enabled <- field
        retentionHours <- field
        assignedHost <- field
        manualAssign <- field
        onvifPort <- field
        mgmtProto <- field
        mainVideoEncoding <- field
        mainVideoWidth <- field
        mainVideoHeight <- field
        mainVideoFps <- field
        mainVideoBitrateKbps <- field
        mainVideoGovLength <- field
        subVideoEncoding <- field
        subVideoWidth <- field
        subVideoHeight <- field
        subVideoFps <- field
        subVideoBitrateKbps <- field
        subVideoGovLength <- field
        audioEncoding <- field
        audioBitrateKbps <- field
        audioSampleRateKhz <- field
        ptzEnabled <- field
        ptzProfileToken <- field
        ptzHomePresetId <- field
        ptzIdleTimeoutS <- field
        ptzViewerControl <- field
        createdAt <- field
        updatedAt <- field
        let theRecord = Generated.ActualTypes.Camera id slug name rtspUrl rtspTransport host username passwordEnc passwordNonce codec rtspSubUrl useSubstreamForAnalysis substreamCodec substreamWidth substreamHeight recordAudio analysisFps modelName enabled retentionHours assignedHost manualAssign onvifPort mgmtProto mainVideoEncoding mainVideoWidth mainVideoHeight mainVideoFps mainVideoBitrateKbps mainVideoGovLength subVideoEncoding subVideoWidth subVideoHeight subVideoFps subVideoBitrateKbps subVideoGovLength audioEncoding audioBitrateKbps audioSampleRateKhz ptzEnabled ptzProfileToken ptzHomePresetId ptzIdleTimeoutS ptzViewerControl createdAt updatedAt def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
        pure theRecord

instance FromRowHasql Generated.ActualTypes.Camera where
    hasqlRowDecoder = Generated.Statements.RowDecoderCamera.rowDecoder

type instance GetModelName (Camera' _) = "Camera"

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
    newRecord = Generated.ActualTypes.Camera def def def def "tcp" def def def def def def True def def def False def "yolov8n-320" True def def False def "onvif" def def def def def def def def def def def def def def def False def def def False def def  def


instance QueryBuilder.FilterPrimaryKey "cameras" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (Camera' ptzHomePresetId) (Id' "cameras") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "slug" (Camera' ptzHomePresetId) Text where
    {-# INLINE setField #-}
    setField newValue record = record { slug = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "name" (Camera' ptzHomePresetId) Text where
    {-# INLINE setField #-}
    setField newValue record = record { name = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "rtspUrl" (Camera' ptzHomePresetId) Text where
    {-# INLINE setField #-}
    setField newValue record = record { rtspUrl = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "rtspTransport" (Camera' ptzHomePresetId) Text where
    {-# INLINE setField #-}
    setField newValue record = record { rtspTransport = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance SetField "host" (Camera' ptzHomePresetId) (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { host = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance SetField "username" (Camera' ptzHomePresetId) (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { username = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance SetField "passwordEnc" (Camera' ptzHomePresetId) (Maybe (Binary ByteString)) where
    {-# INLINE setField #-}
    setField newValue record = record { passwordEnc = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance SetField "passwordNonce" (Camera' ptzHomePresetId) (Maybe (Binary ByteString)) where
    {-# INLINE setField #-}
    setField newValue record = record { passwordNonce = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance SetField "codec" (Camera' ptzHomePresetId) CodecKind where
    {-# INLINE setField #-}
    setField newValue record = record { codec = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 512 } }
instance SetField "rtspSubUrl" (Camera' ptzHomePresetId) (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { rtspSubUrl = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1024 } }
instance SetField "useSubstreamForAnalysis" (Camera' ptzHomePresetId) Bool where
    {-# INLINE setField #-}
    setField newValue record = record { useSubstreamForAnalysis = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2048 } }
instance SetField "substreamCodec" (Camera' ptzHomePresetId) CodecKind where
    {-# INLINE setField #-}
    setField newValue record = record { substreamCodec = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4096 } }
instance SetField "substreamWidth" (Camera' ptzHomePresetId) (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { substreamWidth = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8192 } }
instance SetField "substreamHeight" (Camera' ptzHomePresetId) (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { substreamHeight = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16384 } }
instance SetField "recordAudio" (Camera' ptzHomePresetId) Bool where
    {-# INLINE setField #-}
    setField newValue record = record { recordAudio = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32768 } }
instance SetField "analysisFps" (Camera' ptzHomePresetId) Int where
    {-# INLINE setField #-}
    setField newValue record = record { analysisFps = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 65536 } }
instance SetField "modelName" (Camera' ptzHomePresetId) Text where
    {-# INLINE setField #-}
    setField newValue record = record { modelName = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 131072 } }
instance SetField "enabled" (Camera' ptzHomePresetId) Bool where
    {-# INLINE setField #-}
    setField newValue record = record { enabled = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 262144 } }
instance SetField "retentionHours" (Camera' ptzHomePresetId) Int where
    {-# INLINE setField #-}
    setField newValue record = record { retentionHours = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 524288 } }
instance SetField "assignedHost" (Camera' ptzHomePresetId) (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { assignedHost = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1048576 } }
instance SetField "manualAssign" (Camera' ptzHomePresetId) Bool where
    {-# INLINE setField #-}
    setField newValue record = record { manualAssign = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2097152 } }
instance SetField "onvifPort" (Camera' ptzHomePresetId) (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { onvifPort = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4194304 } }
instance SetField "mgmtProto" (Camera' ptzHomePresetId) Text where
    {-# INLINE setField #-}
    setField newValue record = record { mgmtProto = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8388608 } }
instance SetField "mainVideoEncoding" (Camera' ptzHomePresetId) (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { mainVideoEncoding = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16777216 } }
instance SetField "mainVideoWidth" (Camera' ptzHomePresetId) (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { mainVideoWidth = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 33554432 } }
instance SetField "mainVideoHeight" (Camera' ptzHomePresetId) (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { mainVideoHeight = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 67108864 } }
instance SetField "mainVideoFps" (Camera' ptzHomePresetId) (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { mainVideoFps = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 134217728 } }
instance SetField "mainVideoBitrateKbps" (Camera' ptzHomePresetId) (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { mainVideoBitrateKbps = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 268435456 } }
instance SetField "mainVideoGovLength" (Camera' ptzHomePresetId) (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { mainVideoGovLength = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 536870912 } }
instance SetField "subVideoEncoding" (Camera' ptzHomePresetId) (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { subVideoEncoding = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1073741824 } }
instance SetField "subVideoWidth" (Camera' ptzHomePresetId) (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { subVideoWidth = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2147483648 } }
instance SetField "subVideoHeight" (Camera' ptzHomePresetId) (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { subVideoHeight = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4294967296 } }
instance SetField "subVideoFps" (Camera' ptzHomePresetId) (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { subVideoFps = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8589934592 } }
instance SetField "subVideoBitrateKbps" (Camera' ptzHomePresetId) (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { subVideoBitrateKbps = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 17179869184 } }
instance SetField "subVideoGovLength" (Camera' ptzHomePresetId) (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { subVideoGovLength = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 34359738368 } }
instance SetField "audioEncoding" (Camera' ptzHomePresetId) (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { audioEncoding = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 68719476736 } }
instance SetField "audioBitrateKbps" (Camera' ptzHomePresetId) (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { audioBitrateKbps = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 137438953472 } }
instance SetField "audioSampleRateKhz" (Camera' ptzHomePresetId) (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { audioSampleRateKhz = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 274877906944 } }
instance SetField "ptzEnabled" (Camera' ptzHomePresetId) Bool where
    {-# INLINE setField #-}
    setField newValue record = record { ptzEnabled = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 549755813888 } }
instance SetField "ptzProfileToken" (Camera' ptzHomePresetId) (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { ptzProfileToken = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1099511627776 } }
instance SetField "ptzHomePresetId" (Camera' ptzHomePresetId) ptzHomePresetId where
    {-# INLINE setField #-}
    setField newValue record = record { ptzHomePresetId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2199023255552 } }
instance SetField "ptzIdleTimeoutS" (Camera' ptzHomePresetId) Int where
    {-# INLINE setField #-}
    setField newValue record = record { ptzIdleTimeoutS = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4398046511104 } }
instance SetField "ptzViewerControl" (Camera' ptzHomePresetId) Bool where
    {-# INLINE setField #-}
    setField newValue record = record { ptzViewerControl = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8796093022208 } }
instance SetField "createdAt" (Camera' ptzHomePresetId) UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 17592186044416 } }
instance SetField "updatedAt" (Camera' ptzHomePresetId) UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { updatedAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 35184372088832 } }
instance SetField "meta" (Camera' ptzHomePresetId) MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Id' "cameras") (Id' "cameras") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "slug" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { slug = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "name" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { name = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "rtspUrl" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { rtspUrl = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "rtspTransport" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { rtspTransport = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance UpdateField "host" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { host = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance UpdateField "username" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { username = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance UpdateField "passwordEnc" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe (Binary ByteString)) (Maybe (Binary ByteString)) where
    {-# INLINE updateField #-}
    updateField newValue record = record { passwordEnc = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance UpdateField "passwordNonce" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe (Binary ByteString)) (Maybe (Binary ByteString)) where
    {-# INLINE updateField #-}
    updateField newValue record = record { passwordNonce = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance UpdateField "codec" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) CodecKind CodecKind where
    {-# INLINE updateField #-}
    updateField newValue record = record { codec = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 512 } }
instance UpdateField "rtspSubUrl" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { rtspSubUrl = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1024 } }
instance UpdateField "useSubstreamForAnalysis" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { useSubstreamForAnalysis = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2048 } }
instance UpdateField "substreamCodec" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) CodecKind CodecKind where
    {-# INLINE updateField #-}
    updateField newValue record = record { substreamCodec = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4096 } }
instance UpdateField "substreamWidth" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { substreamWidth = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8192 } }
instance UpdateField "substreamHeight" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { substreamHeight = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16384 } }
instance UpdateField "recordAudio" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { recordAudio = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32768 } }
instance UpdateField "analysisFps" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) Int Int where
    {-# INLINE updateField #-}
    updateField newValue record = record { analysisFps = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 65536 } }
instance UpdateField "modelName" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { modelName = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 131072 } }
instance UpdateField "enabled" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { enabled = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 262144 } }
instance UpdateField "retentionHours" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) Int Int where
    {-# INLINE updateField #-}
    updateField newValue record = record { retentionHours = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 524288 } }
instance UpdateField "assignedHost" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { assignedHost = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1048576 } }
instance UpdateField "manualAssign" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { manualAssign = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2097152 } }
instance UpdateField "onvifPort" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { onvifPort = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4194304 } }
instance UpdateField "mgmtProto" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { mgmtProto = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8388608 } }
instance UpdateField "mainVideoEncoding" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { mainVideoEncoding = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16777216 } }
instance UpdateField "mainVideoWidth" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { mainVideoWidth = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 33554432 } }
instance UpdateField "mainVideoHeight" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { mainVideoHeight = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 67108864 } }
instance UpdateField "mainVideoFps" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { mainVideoFps = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 134217728 } }
instance UpdateField "mainVideoBitrateKbps" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { mainVideoBitrateKbps = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 268435456 } }
instance UpdateField "mainVideoGovLength" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { mainVideoGovLength = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 536870912 } }
instance UpdateField "subVideoEncoding" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { subVideoEncoding = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1073741824 } }
instance UpdateField "subVideoWidth" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { subVideoWidth = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2147483648 } }
instance UpdateField "subVideoHeight" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { subVideoHeight = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4294967296 } }
instance UpdateField "subVideoFps" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { subVideoFps = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8589934592 } }
instance UpdateField "subVideoBitrateKbps" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { subVideoBitrateKbps = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 17179869184 } }
instance UpdateField "subVideoGovLength" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { subVideoGovLength = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 34359738368 } }
instance UpdateField "audioEncoding" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { audioEncoding = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 68719476736 } }
instance UpdateField "audioBitrateKbps" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { audioBitrateKbps = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 137438953472 } }
instance UpdateField "audioSampleRateKhz" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { audioSampleRateKhz = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 274877906944 } }
instance UpdateField "ptzEnabled" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { ptzEnabled = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 549755813888 } }
instance UpdateField "ptzProfileToken" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { ptzProfileToken = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1099511627776 } }
instance UpdateField "ptzHomePresetId" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId') ptzHomePresetId ptzHomePresetId' where
    {-# INLINE updateField #-}
    updateField newValue (Camera id slug name rtspUrl rtspTransport host username passwordEnc passwordNonce codec rtspSubUrl useSubstreamForAnalysis substreamCodec substreamWidth substreamHeight recordAudio analysisFps modelName enabled retentionHours assignedHost manualAssign onvifPort mgmtProto mainVideoEncoding mainVideoWidth mainVideoHeight mainVideoFps mainVideoBitrateKbps mainVideoGovLength subVideoEncoding subVideoWidth subVideoHeight subVideoFps subVideoBitrateKbps subVideoGovLength audioEncoding audioBitrateKbps audioSampleRateKhz ptzEnabled ptzProfileToken ptzHomePresetId ptzIdleTimeoutS ptzViewerControl createdAt updatedAt meta) = Camera id slug name rtspUrl rtspTransport host username passwordEnc passwordNonce codec rtspSubUrl useSubstreamForAnalysis substreamCodec substreamWidth substreamHeight recordAudio analysisFps modelName enabled retentionHours assignedHost manualAssign onvifPort mgmtProto mainVideoEncoding mainVideoWidth mainVideoHeight mainVideoFps mainVideoBitrateKbps mainVideoGovLength subVideoEncoding subVideoWidth subVideoHeight subVideoFps subVideoBitrateKbps subVideoGovLength audioEncoding audioBitrateKbps audioSampleRateKhz ptzEnabled ptzProfileToken newValue ptzIdleTimeoutS ptzViewerControl createdAt updatedAt (meta { touchedFields = touchedFields meta .|. 2199023255552 })
instance UpdateField "ptzIdleTimeoutS" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) Int Int where
    {-# INLINE updateField #-}
    updateField newValue record = record { ptzIdleTimeoutS = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4398046511104 } }
instance UpdateField "ptzViewerControl" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { ptzViewerControl = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8796093022208 } }
instance UpdateField "createdAt" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 17592186044416 } }
instance UpdateField "updatedAt" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { updatedAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 35184372088832 } }
instance UpdateField "meta" (Camera' ptzHomePresetId) (Camera' ptzHomePresetId) MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (Camera' ptzHomePresetId) where fieldBit = 1
instance FieldBit "slug" (Camera' ptzHomePresetId) where fieldBit = 2
instance FieldBit "name" (Camera' ptzHomePresetId) where fieldBit = 4
instance FieldBit "rtspUrl" (Camera' ptzHomePresetId) where fieldBit = 8
instance FieldBit "rtspTransport" (Camera' ptzHomePresetId) where fieldBit = 16
instance FieldBit "host" (Camera' ptzHomePresetId) where fieldBit = 32
instance FieldBit "username" (Camera' ptzHomePresetId) where fieldBit = 64
instance FieldBit "passwordEnc" (Camera' ptzHomePresetId) where fieldBit = 128
instance FieldBit "passwordNonce" (Camera' ptzHomePresetId) where fieldBit = 256
instance FieldBit "codec" (Camera' ptzHomePresetId) where fieldBit = 512
instance FieldBit "rtspSubUrl" (Camera' ptzHomePresetId) where fieldBit = 1024
instance FieldBit "useSubstreamForAnalysis" (Camera' ptzHomePresetId) where fieldBit = 2048
instance FieldBit "substreamCodec" (Camera' ptzHomePresetId) where fieldBit = 4096
instance FieldBit "substreamWidth" (Camera' ptzHomePresetId) where fieldBit = 8192
instance FieldBit "substreamHeight" (Camera' ptzHomePresetId) where fieldBit = 16384
instance FieldBit "recordAudio" (Camera' ptzHomePresetId) where fieldBit = 32768
instance FieldBit "analysisFps" (Camera' ptzHomePresetId) where fieldBit = 65536
instance FieldBit "modelName" (Camera' ptzHomePresetId) where fieldBit = 131072
instance FieldBit "enabled" (Camera' ptzHomePresetId) where fieldBit = 262144
instance FieldBit "retentionHours" (Camera' ptzHomePresetId) where fieldBit = 524288
instance FieldBit "assignedHost" (Camera' ptzHomePresetId) where fieldBit = 1048576
instance FieldBit "manualAssign" (Camera' ptzHomePresetId) where fieldBit = 2097152
instance FieldBit "onvifPort" (Camera' ptzHomePresetId) where fieldBit = 4194304
instance FieldBit "mgmtProto" (Camera' ptzHomePresetId) where fieldBit = 8388608
instance FieldBit "mainVideoEncoding" (Camera' ptzHomePresetId) where fieldBit = 16777216
instance FieldBit "mainVideoWidth" (Camera' ptzHomePresetId) where fieldBit = 33554432
instance FieldBit "mainVideoHeight" (Camera' ptzHomePresetId) where fieldBit = 67108864
instance FieldBit "mainVideoFps" (Camera' ptzHomePresetId) where fieldBit = 134217728
instance FieldBit "mainVideoBitrateKbps" (Camera' ptzHomePresetId) where fieldBit = 268435456
instance FieldBit "mainVideoGovLength" (Camera' ptzHomePresetId) where fieldBit = 536870912
instance FieldBit "subVideoEncoding" (Camera' ptzHomePresetId) where fieldBit = 1073741824
instance FieldBit "subVideoWidth" (Camera' ptzHomePresetId) where fieldBit = 2147483648
instance FieldBit "subVideoHeight" (Camera' ptzHomePresetId) where fieldBit = 4294967296
instance FieldBit "subVideoFps" (Camera' ptzHomePresetId) where fieldBit = 8589934592
instance FieldBit "subVideoBitrateKbps" (Camera' ptzHomePresetId) where fieldBit = 17179869184
instance FieldBit "subVideoGovLength" (Camera' ptzHomePresetId) where fieldBit = 34359738368
instance FieldBit "audioEncoding" (Camera' ptzHomePresetId) where fieldBit = 68719476736
instance FieldBit "audioBitrateKbps" (Camera' ptzHomePresetId) where fieldBit = 137438953472
instance FieldBit "audioSampleRateKhz" (Camera' ptzHomePresetId) where fieldBit = 274877906944
instance FieldBit "ptzEnabled" (Camera' ptzHomePresetId) where fieldBit = 549755813888
instance FieldBit "ptzProfileToken" (Camera' ptzHomePresetId) where fieldBit = 1099511627776
instance FieldBit "ptzHomePresetId" (Camera' ptzHomePresetId) where fieldBit = 2199023255552
instance FieldBit "ptzIdleTimeoutS" (Camera' ptzHomePresetId) where fieldBit = 4398046511104
instance FieldBit "ptzViewerControl" (Camera' ptzHomePresetId) where fieldBit = 8796093022208
instance FieldBit "createdAt" (Camera' ptzHomePresetId) where fieldBit = 17592186044416
instance FieldBit "updatedAt" (Camera' ptzHomePresetId) where fieldBit = 35184372088832


