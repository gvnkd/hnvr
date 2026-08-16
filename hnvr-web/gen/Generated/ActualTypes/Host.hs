-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE ConstraintKinds #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE DataKinds #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE FlexibleInstances #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE InstanceSigs #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE MultiParamTypeClasses #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE StandaloneDeriving #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeFamilies #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeOperators #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances #-}
-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}

module Generated.ActualTypes.Host where

import qualified Control.DeepSeq as DeepSeq
import Control.Monad (unless)
import CorePrelude hiding (id)
import qualified Data.Aeson
import Data.Bits ((.&.), (.|.))
import qualified Data.ByteString as ByteString
import Data.Data
import Data.Default
import qualified Data.Dynamic
import qualified Data.List as List
import qualified Data.Proxy
import Data.Scientific
import qualified Data.String.Conversions
import qualified Data.Text.Encoding
import qualified Data.Time.Calendar
import Data.Time.Clock
import Data.Time.LocalTime
import Data.UUID (UUID)
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.FromField hiding (Field, name)
import Database.PostgreSQL.Simple.FromRow
import Database.PostgreSQL.Simple.ToField hiding (Field)
import Database.PostgreSQL.Simple.Types (Binary (..), Query (Query))
import qualified Database.PostgreSQL.Simple.Types
import GHC.Records
import GHC.TypeLits
import Generated.ActualTypes.PrimaryKeys
import Generated.Enums
import qualified Hasql.Decoders as Decoders
import qualified Hasql.Encoders
import qualified Hasql.Implicits.Encoders
import qualified Hasql.Mapping.IsScalar as Mapping
import Hasql.PostgresqlTypes ()
import qualified IHP.Controller.Param
import IHP.HaskellSupport
import IHP.Hasql.Encoders ()
import IHP.Hasql.FromRow (FromRowHasql (..))
import IHP.Job.Queue (textToEnumJobStatus)
import IHP.Job.Types
import IHP.ModelSupport
import qualified IHP.QueryBuilder as QueryBuilder

data Host' = Host {id :: (Id' "hosts"), gpuModel :: (Maybe Text), execProviders :: [Text], isLeader :: Bool, lastHealthAt :: (Maybe UTCTime), healthJson :: (Maybe Data.Aeson.Value), createdAt :: UTCTime, meta :: MetaBag} deriving (Eq, Show)

type Host = Host'

type instance GetTableName (Host') = "hosts"

type instance GetModelByTableName "hosts" = Host

instance IHP.ModelSupport.Table (Host') where
  tableName = "hosts"
  columnNames = ["id", "gpu_model", "exec_providers", "is_leader", "last_health_at", "health_json", "created_at"]
  primaryKeyColumnNames = ["id"]
