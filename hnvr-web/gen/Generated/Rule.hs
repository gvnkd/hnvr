-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.Rule where
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
import qualified Generated.Statements.RowDecoderRule
import qualified Generated.Statements.CreateRule
import qualified Generated.Statements.UpdateRule
import qualified Generated.Statements.CreateManyRule
instance InputValue Generated.ActualTypes.Rule where inputValue = IHP.ModelSupport.recordToInputValue

instance FromRow Generated.ActualTypes.Rule where
    fromRow = do
        id <- field
        cameraId <- field
        name <- field
        kind <- field
        geometry <- field
        classes <- field
        cooldownMs <- field
        clipPrerollSec <- field
        clipPostrollSec <- field
        clipRetentionHours <- field
        enabled <- field
        createdAt <- field
        updatedAt <- field
        let theRecord = Generated.ActualTypes.Rule id cameraId name kind geometry classes cooldownMs clipPrerollSec clipPostrollSec clipRetentionHours enabled createdAt updatedAt def { originalDatabaseRecord = Just (Data.Dynamic.toDyn theRecord) }
        pure theRecord

instance FromRowHasql Generated.ActualTypes.Rule where
    hasqlRowDecoder = Generated.Statements.RowDecoderRule.rowDecoder

type instance GetModelName (Rule') = "Rule"

instance CanCreate Generated.ActualTypes.Rule where
    create = createRule
    createMany = createManyRule
    createRecordDiscardResult = createRecordDiscardResultRule

createRule :: (?modelContext :: ModelContext) => Generated.ActualTypes.Rule -> IO Generated.ActualTypes.Rule
createRule model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateRule.statement touched)

createManyRule :: (?modelContext :: ModelContext) => [Generated.ActualTypes.Rule] -> IO [Generated.ActualTypes.Rule]
createManyRule [] = pure []
createManyRule models = do
    let pool = ?modelContext.hasqlPool
    let touchedList = List.map (\model -> model.meta.touchedFields) models
    sqlStatementHasql pool models (Generated.Statements.CreateManyRule.statement touchedList)

createRecordDiscardResultRule :: (?modelContext :: ModelContext) => Generated.ActualTypes.Rule -> IO ()
createRecordDiscardResultRule model = do
    let pool = ?modelContext.hasqlPool
    let touched = model.meta.touchedFields
    sqlStatementHasql pool model (Generated.Statements.CreateRule.discardResultStatement touched)

instance CanUpdate Generated.ActualTypes.Rule where
    updateRecord = updateRecordRule
    updateRecordDiscardResult = updateRecordDiscardResultRule

updateRecordRule :: (?modelContext :: ModelContext) => Generated.ActualTypes.Rule -> IO Generated.ActualTypes.Rule
updateRecordRule model = do
    let touched = model.meta.touchedFields
    if touched == 0 then pure model else do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateRule.statement touched)

updateRecordDiscardResultRule :: (?modelContext :: ModelContext) => Generated.ActualTypes.Rule -> IO ()
updateRecordDiscardResultRule model = do
    let touched = model.meta.touchedFields
    unless (touched == 0) $ do
        let pool = ?modelContext.hasqlPool
        sqlStatementHasql pool model (Generated.Statements.UpdateRule.discardResultStatement touched)

instance Record Generated.ActualTypes.Rule where
    {-# INLINE newRecord #-}
    newRecord = Generated.ActualTypes.Rule def def def def def def def def def def True def def  def


instance QueryBuilder.FilterPrimaryKey "rules" where
    filterWhereId id builder =
        builder |> QueryBuilder.filterWhere (#id, id)
    {-# INLINE filterWhereId #-}

instance SetField "id" (Rule') (Id' "rules") where
    {-# INLINE setField #-}
    setField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance SetField "cameraId" (Rule') UUID where
    {-# INLINE setField #-}
    setField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance SetField "name" (Rule') Text where
    {-# INLINE setField #-}
    setField newValue record = record { name = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance SetField "kind" (Rule') RuleKind where
    {-# INLINE setField #-}
    setField newValue record = record { kind = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance SetField "geometry" (Rule') Data.Aeson.Value where
    {-# INLINE setField #-}
    setField newValue record = record { geometry = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance SetField "classes" (Rule') [Int] where
    {-# INLINE setField #-}
    setField newValue record = record { classes = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance SetField "cooldownMs" (Rule') Int where
    {-# INLINE setField #-}
    setField newValue record = record { cooldownMs = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance SetField "clipPrerollSec" (Rule') Int where
    {-# INLINE setField #-}
    setField newValue record = record { clipPrerollSec = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance SetField "clipPostrollSec" (Rule') Int where
    {-# INLINE setField #-}
    setField newValue record = record { clipPostrollSec = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance SetField "clipRetentionHours" (Rule') (Maybe Int) where
    {-# INLINE setField #-}
    setField newValue record = record { clipRetentionHours = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 512 } }
instance SetField "enabled" (Rule') Bool where
    {-# INLINE setField #-}
    setField newValue record = record { enabled = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1024 } }
instance SetField "createdAt" (Rule') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2048 } }
instance SetField "updatedAt" (Rule') UTCTime where
    {-# INLINE setField #-}
    setField newValue record = record { updatedAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4096 } }
instance SetField "meta" (Rule') MetaBag where
    {-# INLINE setField #-}
    setField newValue record = record { meta = newValue }
instance UpdateField "id" (Rule') (Rule') (Id' "rules") (Id' "rules") where
    {-# INLINE updateField #-}
    updateField newValue record = record { id = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1 } }
instance UpdateField "cameraId" (Rule') (Rule') UUID UUID where
    {-# INLINE updateField #-}
    updateField newValue record = record { cameraId = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2 } }
instance UpdateField "name" (Rule') (Rule') Text Text where
    {-# INLINE updateField #-}
    updateField newValue record = record { name = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4 } }
instance UpdateField "kind" (Rule') (Rule') RuleKind RuleKind where
    {-# INLINE updateField #-}
    updateField newValue record = record { kind = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 8 } }
instance UpdateField "geometry" (Rule') (Rule') Data.Aeson.Value Data.Aeson.Value where
    {-# INLINE updateField #-}
    updateField newValue record = record { geometry = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 16 } }
instance UpdateField "classes" (Rule') (Rule') [Int] [Int] where
    {-# INLINE updateField #-}
    updateField newValue record = record { classes = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 32 } }
instance UpdateField "cooldownMs" (Rule') (Rule') Int Int where
    {-# INLINE updateField #-}
    updateField newValue record = record { cooldownMs = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 64 } }
instance UpdateField "clipPrerollSec" (Rule') (Rule') Int Int where
    {-# INLINE updateField #-}
    updateField newValue record = record { clipPrerollSec = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 128 } }
instance UpdateField "clipPostrollSec" (Rule') (Rule') Int Int where
    {-# INLINE updateField #-}
    updateField newValue record = record { clipPostrollSec = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 256 } }
instance UpdateField "clipRetentionHours" (Rule') (Rule') (Maybe Int) (Maybe Int) where
    {-# INLINE updateField #-}
    updateField newValue record = record { clipRetentionHours = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 512 } }
instance UpdateField "enabled" (Rule') (Rule') Bool Bool where
    {-# INLINE updateField #-}
    updateField newValue record = record { enabled = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 1024 } }
instance UpdateField "createdAt" (Rule') (Rule') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { createdAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 2048 } }
instance UpdateField "updatedAt" (Rule') (Rule') UTCTime UTCTime where
    {-# INLINE updateField #-}
    updateField newValue record = record { updatedAt = newValue, meta = record.meta { touchedFields = record.meta.touchedFields .|. 4096 } }
instance UpdateField "meta" (Rule') (Rule') MetaBag MetaBag where
    {-# INLINE updateField #-}
    updateField newValue record = record { meta = newValue }

instance FieldBit "id" (Rule') where fieldBit = 1
instance FieldBit "cameraId" (Rule') where fieldBit = 2
instance FieldBit "name" (Rule') where fieldBit = 4
instance FieldBit "kind" (Rule') where fieldBit = 8
instance FieldBit "geometry" (Rule') where fieldBit = 16
instance FieldBit "classes" (Rule') where fieldBit = 32
instance FieldBit "cooldownMs" (Rule') where fieldBit = 64
instance FieldBit "clipPrerollSec" (Rule') where fieldBit = 128
instance FieldBit "clipPostrollSec" (Rule') where fieldBit = 256
instance FieldBit "clipRetentionHours" (Rule') where fieldBit = 512
instance FieldBit "enabled" (Rule') where fieldBit = 1024
instance FieldBit "createdAt" (Rule') where fieldBit = 2048
instance FieldBit "updatedAt" (Rule') where fieldBit = 4096


