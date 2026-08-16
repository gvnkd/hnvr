-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}

module Generated.Statements.FetchHost (statement) where

import qualified Data.Aeson
import Data.Default (def)
import qualified Data.Dynamic
import Data.Functor.Contravariant (contramap, (>$<))
import Data.Int (Int16, Int32, Int64)
import Data.Scientific (Scientific)
import Data.Text (Text)
import qualified Data.Time.Calendar
import Data.Time.Clock (UTCTime)
import Data.Time.LocalTime (LocalTime, TimeOfDay)
import Data.UUID (UUID)
import qualified Database.PostgreSQL.Simple.Types
import Generated.ActualTypes
import Generated.Enums
import qualified Generated.Statements.RowDecoderHost as RowDecoder
import qualified Hasql.Decoders as Decoders
import qualified Hasql.Encoders as Encoders
import qualified Hasql.Mapping.IsScalar as Mapping
import Hasql.PostgresqlTypes ()
import qualified Hasql.Statement as Statement
import IHP.Job.Queue ()
import IHP.ModelSupport.Types (Id' (..), MetaBag (..))
import PostgresqlTypes.Inet (Inet)
import PostgresqlTypes.Interval (Interval)
import PostgresqlTypes.Point (Point)
import PostgresqlTypes.Polygon (Polygon)
import PostgresqlTypes.Tsvector (Tsvector)
import Prelude (Bool (..), Int, Integer, Maybe (..), fromIntegral, length, map, mconcat, not, null, pure, show, zip, (!!), ($), (&&), (*), (+), (++), (-), (.), (<$>), (<*>), (<>))

statement :: Statement.Statement (Id' "hosts") (Maybe Generated.ActualTypes.Host)
statement = Statement.preparable sql encoder decoder

sql :: Text
sql = "SELECT id, gpu_model, exec_providers, is_leader, last_health_at, health_json, created_at FROM hosts WHERE id = $1 LIMIT 1"

encoder :: Encoders.Params (Id' "hosts")
encoder = Encoders.param (Encoders.nonNullable Mapping.encoder)

decoder :: Decoders.Result (Maybe Generated.ActualTypes.Host)
decoder = Decoders.rowMaybe RowDecoder.rowDecoder
