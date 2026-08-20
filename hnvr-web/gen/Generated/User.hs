-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.User where
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
import qualified Generated.Statements.RowDecoderUser
import qualified Generated.Statements.CreateUser
import qualified Generated.Statements.UpdateUser
import qualified Generated.Statements.CreateManyUser
instance InputValue Generated.ActualTypes.User where inputValue = IHP.ModelSupport.recordToInputValue

instance FromRow Generated.ActualTypes.User where
    fromRow = do
        id <- field
        email <- field
        passwordHash <- field
        isAdmin <- field
        lockedAt <- field
        failedLoginAttempts <- field
        lastLoginAt <- field
        timezone <- field
        createdAt <- field
        let theRecord = Generated.ActualTypes.User id email passwordHash isAdmin lockedAt failedLoginAttempts lastLoginAt timezone createdAt def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
        pure theRecord

instance FromRowHasql Generated.ActualTypes.User where
    hasqlRowDecoder = Generated.Statements.RowDecoderUser.rowDecoder

type instance GetModelName (User') = "User"

instance CanCreate Generated.ActualTypes.User where
    create = createUser
    createMany = createManyUser
    createRecordDiscardResult = createRecordDiscardResultUser

createUser :: (?modelContext :: ModelContext) => Generated.ActualTypes.User -> IO Generated.ActualTypes.User
createUser model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateUser.statement touched)

createManyUser :: (?modelContext :: ModelContext) => [Generated.ActualTypes.User] -> IO [Generated.ActualTypes.User]
createManyUser [] = pure []
createManyUser models = do
    let pool = ?modelContext.hasqlPool
    let touchedList = List.map (\model -> model.meta.touchedFields) models
    sqlStatementHasql pool models (Generated.Statements.CreateManyUser.statement touchedList)

createRecordDiscardResultUser :: (?modelContext :: ModelContext) => Generated.ActualTypes.User -> IO ()
createRecordDiscardResultUser model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateUser.discardResultStatement touched)

instance CanUpdate Generated.ActualTypes.User where
    updateRecord = updateRecordUser
    updateRecordDiscardResult = updateRecordDiscardResultUser

updateRecordUser :: (?modelContext :: ModelContext) => Generated.ActualTypes.User -> IO Generated.ActualTypes.User
updateRecordUser model = do
    let touched = model.meta.touchedFields
    if touched == 0 then pure model else do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateUser.statement touched)

updateRecordDiscardResultUser :: (?modelContext :: ModelContext) => Generated.ActualTypes.User -> IO ()
updateRecordDiscardResultUser model = do
    let touched = model.meta.touchedFields
    unless (touched == 0) $ do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateUser.discardResultStatement touched)

instance Record Generated.ActualTypes.User where
    {-# INLINE newRecord #-}
    newRecord = Generated.ActualTypes.User def def def False def def def def def  def


instance QueryBuilder.FilterPrimaryKey "users" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (User') (Id' "users") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "email" (User') Text where
    {-# INLINE setField #-}
    setField newValue record = record { email = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "passwordHash" (User') Text where
    {-# INLINE setField #-}
    setField newValue record = record { passwordHash = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "isAdmin" (User') Bool where
    {-# INLINE setField #-}
    setField newValue record = record { isAdmin = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "lockedAt" (User') (Maybe UTCTime) where
    {-# INLINE setField #-}
    setField newValue record = record { lockedAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance SetField "failedLoginAttempts" (User') Int where
    {-# INLINE setField #-}
    setField newValue record = record { failedLoginAttempts = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance SetField "lastLoginAt" (User') (Maybe UTCTime) where
    {-# INLINE setField #-}
    setField newValue record = record { lastLoginAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance SetField "timezone" (User') (Maybe Text) where
    {-# INLINE setField #-}
    setField newValue record = record { timezone = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance SetField "createdAt" (User') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance SetField "meta" (User') MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (User') (User') (Id' "users") (Id' "users") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "email" (User') (User') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { email = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "passwordHash" (User') (User') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { passwordHash = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "isAdmin" (User') (User') Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { isAdmin = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "lockedAt" (User') (User') (Maybe UTCTime) (Maybe UTCTime) where
    {-# INLINE updateField #-}
    updateField newValue record = record { lockedAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance UpdateField "failedLoginAttempts" (User') (User') Int Int where
    {-# INLINE updateField #-}
    updateField newValue record = record { failedLoginAttempts = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance UpdateField "lastLoginAt" (User') (User') (Maybe UTCTime) (Maybe UTCTime) where
    {-# INLINE updateField #-}
    updateField newValue record = record { lastLoginAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance UpdateField "timezone" (User') (User') (Maybe Text) (Maybe Text) where
    {-# INLINE updateField #-}
    updateField newValue record = record { timezone = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance UpdateField "createdAt" (User') (User') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance UpdateField "meta" (User') (User') MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (User') where fieldBit = 1
instance FieldBit "email" (User') where fieldBit = 2
instance FieldBit "passwordHash" (User') where fieldBit = 4
instance FieldBit "isAdmin" (User') where fieldBit = 8
instance FieldBit "lockedAt" (User') where fieldBit = 16
instance FieldBit "failedLoginAttempts" (User') where fieldBit = 32
instance FieldBit "lastLoginAt" (User') where fieldBit = 64
instance FieldBit "timezone" (User') where fieldBit = 128
instance FieldBit "createdAt" (User') where fieldBit = 256


