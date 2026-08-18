-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}
module Generated.Statements.FetchPtzPreset (statement) where

import Prelude (($), (.), (<$>), (<*>), (<>), (+), (*), (-), show, fromIntegral, length, null, zip, mconcat, (++), Maybe(..), (!!), map, Bool(..), Int, Integer, pure, (&&), not)
import Generated.ActualTypes
import Generated.Enums
import IHP.ModelSupport.Types (Id'(..), MetaBag(..))
import qualified Hasql.Statement as Statement
import qualified Hasql.Decoders as Decoders
import qualified Hasql.Encoders as Encoders
import qualified Hasql.Mapping.IsScalar as Mapping
import Hasql.PostgresqlTypes ()
import IHP.Job.Queue ()
import Data.Functor.Contravariant (contramap, (>$<))
import Data.Default (def)
import qualified Data.Dynamic
import Data.UUID (UUID)
import Data.Text (Text)
import Data.Int (Int16, Int32, Int64)
import Data.Time.Clock (UTCTime)
import Data.Time.LocalTime (LocalTime, TimeOfDay)
import qualified Data.Time.Calendar
import Data.Scientific (Scientific)
import qualified Data.Aeson
import qualified Database.PostgreSQL.Simple.Types
import PostgresqlTypes.Point (Point)
import PostgresqlTypes.Polygon (Polygon)
import PostgresqlTypes.Inet (Inet)
import PostgresqlTypes.Tsvector (Tsvector)
import PostgresqlTypes.Interval (Interval)

import qualified Generated.Statements.RowDecoderPtzPreset as RowDecoder
statement :: Statement.Statement (Id' "ptz_presets") (Maybe Generated.ActualTypes.PtzPreset)
statement = Statement.preparable sql encoder decoder

sql :: Text
sql = "SELECT id, camera_id, name, onvif_token, pantilt_x, pantilt_y, zoom, is_home, created_at FROM ptz_presets WHERE id = $1 LIMIT 1"

encoder :: Encoders.Params (Id' "ptz_presets")
encoder = Encoders.param (Encoders.nonNullable Mapping.encoder)

decoder :: Decoders.Result (Maybe Generated.ActualTypes.PtzPreset)
decoder = Decoders.rowMaybe RowDecoder.rowDecoder
