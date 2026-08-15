-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}
module Generated.ActualTypes.PrimaryKeys where
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
import Generated.Enums
type instance PrimaryKey "hosts" = Text
instance Default (Id' "hosts") where def = Id def
type instance PrimaryKey "cameras" = UUID
instance Default (Id' "cameras") where def = Id def
type instance PrimaryKey "segments" = UUID
instance Default (Id' "segments") where def = Id def
type instance PrimaryKey "users" = UUID
instance Default (Id' "users") where def = Id def
type instance PrimaryKey "rules" = UUID
instance Default (Id' "rules") where def = Id def
type instance PrimaryKey "events" = UUID
instance Default (Id' "events") where def = Id def
type instance PrimaryKey "event_clips" = UUID
instance Default (Id' "event_clips") where def = Id def
type instance PrimaryKey "event_clip_events" = UUID
instance Default (Id' "event_clip_events") where def = Id def
type instance PrimaryKey "audit_log" = Integer
instance Default (Id' "audit_log") where def = Id def
