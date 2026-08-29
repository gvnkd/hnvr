-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.AdminAudit where
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
import qualified Generated.Statements.RowDecoderAdminAudit
import qualified Generated.Statements.CreateAdminAudit
import qualified Generated.Statements.UpdateAdminAudit
import qualified Generated.Statements.CreateManyAdminAudit
instance InputValue Generated.ActualTypes.AdminAudit where inputValue = IHP.ModelSupport.recordToInputValue

instance FromRow Generated.ActualTypes.AdminAudit where
    fromRow = do
        id <- field
        actorId <- field
        action <- field
        objectKind <- field
        objectId <- field
        payload <- field
        createdAt <- field
        let theRecord = Generated.ActualTypes.AdminAudit id actorId action objectKind objectId payload createdAt def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
        pure theRecord

instance FromRowHasql Generated.ActualTypes.AdminAudit where
    hasqlRowDecoder = Generated.Statements.RowDecoderAdminAudit.rowDecoder

type instance GetModelName (AdminAudit') = "AdminAudit"

instance CanCreate Generated.ActualTypes.AdminAudit where
    create = createAdminAudit
    createMany = createManyAdminAudit
    createRecordDiscardResult = createRecordDiscardResultAdminAudit

createAdminAudit :: (?modelContext :: ModelContext) => Generated.ActualTypes.AdminAudit -> IO Generated.ActualTypes.AdminAudit
createAdminAudit model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateAdminAudit.statement touched)

createManyAdminAudit :: (?modelContext :: ModelContext) => [Generated.ActualTypes.AdminAudit] -> IO [Generated.ActualTypes.AdminAudit]
createManyAdminAudit [] = pure []
createManyAdminAudit models = do
    let pool = ?modelContext.hasqlPool
    let touchedList = List.map (\model -> model.meta.touchedFields) models
    sqlStatementHasql pool models (Generated.Statements.CreateManyAdminAudit.statement touchedList)

createRecordDiscardResultAdminAudit :: (?modelContext :: ModelContext) => Generated.ActualTypes.AdminAudit -> IO ()
createRecordDiscardResultAdminAudit model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateAdminAudit.discardResultStatement touched)

instance CanUpdate Generated.ActualTypes.AdminAudit where
    updateRecord = updateRecordAdminAudit
    updateRecordDiscardResult = updateRecordDiscardResultAdminAudit

updateRecordAdminAudit :: (?modelContext :: ModelContext) => Generated.ActualTypes.AdminAudit -> IO Generated.ActualTypes.AdminAudit
updateRecordAdminAudit model = do
    let touched = model.meta.touchedFields
    if touched == 0 then pure model else do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateAdminAudit.statement touched)

updateRecordDiscardResultAdminAudit :: (?modelContext :: ModelContext) => Generated.ActualTypes.AdminAudit -> IO ()
updateRecordDiscardResultAdminAudit model = do
    let touched = model.meta.touchedFields
    unless (touched == 0) $ do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateAdminAudit.discardResultStatement touched)

instance Record Generated.ActualTypes.AdminAudit where
    {-# INLINE newRecord #-}
    newRecord = Generated.ActualTypes.AdminAudit def def def def def def def  def


instance QueryBuilder.FilterPrimaryKey "admin_audit" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (AdminAudit') (Id' "admin_audit") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "actorId" (AdminAudit') (Maybe UUID) where
    {-# INLINE setField #-}
    setField newValue record = record { actorId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "action" (AdminAudit') Text where
    {-# INLINE setField #-}
    setField newValue record = record { action = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "objectKind" (AdminAudit') Text where
    {-# INLINE setField #-}
    setField newValue record = record { objectKind = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "objectId" (AdminAudit') (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { objectId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance SetField "payload" (AdminAudit') (Maybe Data.Aeson.Value) where
    {-# INLINE setField #-}
    setField newValue record = record { payload = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance SetField "createdAt" (AdminAudit') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance SetField "meta" (AdminAudit') MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (AdminAudit') (AdminAudit') (Id' "admin_audit") (Id' "admin_audit") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "actorId" (AdminAudit') (AdminAudit') (Maybe UUID) (Maybe UUID) where
    {-# INLINE updateField #-}
    updateField newValue record = record { actorId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "action" (AdminAudit') (AdminAudit') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { action = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "objectKind" (AdminAudit') (AdminAudit') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { objectKind = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "objectId" (AdminAudit') (AdminAudit') (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { objectId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance UpdateField "payload" (AdminAudit') (AdminAudit') (Maybe Data.Aeson.Value) (Maybe Data.Aeson.Value) where
    {-# INLINE updateField #-}
    updateField newValue record = record { payload = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance UpdateField "createdAt" (AdminAudit') (AdminAudit') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance UpdateField "meta" (AdminAudit') (AdminAudit') MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (AdminAudit') where fieldBit = 1
instance FieldBit "actorId" (AdminAudit') where fieldBit = 2
instance FieldBit "action" (AdminAudit') where fieldBit = 4
instance FieldBit "objectKind" (AdminAudit') where fieldBit = 8
instance FieldBit "objectId" (AdminAudit') where fieldBit = 16
instance FieldBit "payload" (AdminAudit') where fieldBit = 32
instance FieldBit "createdAt" (AdminAudit') where fieldBit = 64


