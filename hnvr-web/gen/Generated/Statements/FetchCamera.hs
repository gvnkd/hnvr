-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}

module Generated.Statements.FetchCamera (statement) where

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
import qualified Generated.Statements.RowDecoderCamera as RowDecoder
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

statement :: Statement.Statement (Id' "cameras") (Maybe Generated.ActualTypes.Camera)
statement = Statement.preparable sql encoder decoder

sql :: Text
sql = "SELECT id, slug, name, rtsp_url, rtsp_transport, host, username, password_enc, password_nonce, codec, rtsp_sub_url, use_substream_for_analysis, substream_codec, substream_width, substream_height, record_audio, analysis_fps, model_name, enabled, retention_hours, assigned_host, manual_assign, onvif_port, mgmt_proto, main_video_encoding, main_video_width, main_video_height, main_video_fps, main_video_bitrate_kbps, main_video_gov_length, sub_video_encoding, sub_video_width, sub_video_height, sub_video_fps, sub_video_bitrate_kbps, sub_video_gov_length, audio_encoding, audio_bitrate_kbps, audio_sample_rate_khz, created_at, updated_at FROM cameras WHERE id = $1 LIMIT 1"

encoder :: Encoders.Params (Id' "cameras")
encoder = Encoders.param (Encoders.nonNullable Mapping.encoder)

decoder :: Decoders.Result (Maybe Generated.ActualTypes.Camera)
decoder = Decoders.rowMaybe RowDecoder.rowDecoder
