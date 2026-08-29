-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.Role where
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
import qualified Generated.Statements.RowDecoderRole
import qualified Generated.Statements.CreateRole
import qualified Generated.Statements.UpdateRole
import qualified Generated.Statements.CreateManyRole
instance InputValue Generated.ActualTypes.Role where inputValue = IHP.ModelSupport.recordToInputValue

instance FromRow Generated.ActualTypes.Role where
    fromRow = do
        id <- field
        name <- field
        description <- field
        isSystem <- field
        createdAt <- field
        let theRecord = Generated.ActualTypes.Role id name description isSystem createdAt def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
        pure theRecord

instance FromRowHasql Generated.ActualTypes.Role where
    hasqlRowDecoder = Generated.Statements.RowDecoderRole.rowDecoder

type instance GetModelName (Role') = "Role"

instance CanCreate Generated.ActualTypes.Role where
    create = createRole
    createMany = createManyRole
    createRecordDiscardResult = createRecordDiscardResultRole

createRole :: (?modelContext :: ModelContext) => Generated.ActualTypes.Role -> IO Generated.ActualTypes.Role
createRole model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateRole.statement touched)

createManyRole :: (?modelContext :: ModelContext) => [Generated.ActualTypes.Role] -> IO [Generated.ActualTypes.Role]
createManyRole [] = pure []
createManyRole models = do
    let pool = ?modelContext.hasqlPool
    let touchedList = List.map (\model -> model.meta.touchedFields) models
    sqlStatementHasql pool models (Generated.Statements.CreateManyRole.statement touchedList)

createRecordDiscardResultRole :: (?modelContext :: ModelContext) => Generated.ActualTypes.Role -> IO ()
createRecordDiscardResultRole model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateRole.discardResultStatement touched)

instance CanUpdate Generated.ActualTypes.Role where
    updateRecord = updateRecordRole
    updateRecordDiscardResult = updateRecordDiscardResultRole

updateRecordRole :: (?modelContext :: ModelContext) => Generated.ActualTypes.Role -> IO Generated.ActualTypes.Role
updateRecordRole model = do
    let touched = model.meta.touchedFields
    if touched == 0 then pure model else do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateRole.statement touched)

updateRecordDiscardResultRole :: (?modelContext :: ModelContext) => Generated.ActualTypes.Role -> IO ()
updateRecordDiscardResultRole model = do
    let touched = model.meta.touchedFields
    unless (touched == 0) $ do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateRole.discardResultStatement touched)

instance Record Generated.ActualTypes.Role where
    {-# INLINE newRecord #-}
    newRecord = Generated.ActualTypes.Role def def "" False def  def


instance QueryBuilder.FilterPrimaryKey "roles" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (Role') (Id' "roles") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "name" (Role') Text where
    {-# INLINE setField #-}
    setField newValue record = record { name = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "description" (Role') Text where
    {-# INLINE setField #-}
    setField newValue record = record { description = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "isSystem" (Role') Bool where
    {-# INLINE setField #-}
    setField newValue record = record { isSystem = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "createdAt" (Role') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance SetField "meta" (Role') MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (Role') (Role') (Id' "roles") (Id' "roles") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "name" (Role') (Role') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { name = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "description" (Role') (Role') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { description = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "isSystem" (Role') (Role') Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { isSystem = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "createdAt" (Role') (Role') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance UpdateField "meta" (Role') (Role') MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (Role') where fieldBit = 1
instance FieldBit "name" (Role') where fieldBit = 2
instance FieldBit "description" (Role') where fieldBit = 4
instance FieldBit "isSystem" (Role') where fieldBit = 8
instance FieldBit "createdAt" (Role') where fieldBit = 16


