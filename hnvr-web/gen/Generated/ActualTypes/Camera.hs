-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
{-# LANGUAGE TypeSynonymInstances, FlexibleInstances, InstanceSigs, MultiParamTypeClasses, TypeFamilies, DataKinds, TypeOperators, UndecidableInstances, ConstraintKinds, StandaloneDeriving  #-}
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches -Wno-ambiguous-fields #-}
module Generated.ActualTypes.Camera where
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
import Generated.ActualTypes.PrimaryKeys
data Camera' = Camera {id :: (Id' "cameras"), slug :: Text, name :: Text, rtspUrl :: Text, rtspTemplate :: (Maybe Text), rtspTransport :: Text, host :: (Maybe Text), port :: Int, username :: (Maybe Text), passwordEnc :: (Maybe (Binary ByteString)), passwordNonce :: (Maybe (Binary ByteString)), codec :: CodecKind, rtspSubUrl :: (Maybe Text), rtspSubTemplate :: (Maybe Text), useSubstreamForAnalysis :: Bool, substreamCodec :: CodecKind, substreamWidth :: (Maybe Int), substreamHeight :: (Maybe Int), recordAudio :: Bool, analysisFps :: Int, modelName :: Text, enabled :: Bool, retentionHours :: Int, assignedHost :: (Maybe Text), manualAssign :: Bool, onvifPort :: (Maybe Int), mgmtProto :: Text, mainVideoEncoding :: (Maybe Text), mainVideoWidth :: (Maybe Int), mainVideoHeight :: (Maybe Int), mainVideoFps :: (Maybe Int), mainVideoBitrateKbps :: (Maybe Int), mainVideoGovLength :: (Maybe Int), subVideoEncoding :: (Maybe Text), subVideoWidth :: (Maybe Int), subVideoHeight :: (Maybe Int), subVideoFps :: (Maybe Int), subVideoBitrateKbps :: (Maybe Int), subVideoGovLength :: (Maybe Int), audioEncoding :: (Maybe Text), audioBitrateKbps :: (Maybe Int), audioSampleRateKhz :: (Maybe Int), createdAt :: UTCTime, updatedAt :: UTCTime, meta :: MetaBag} deriving (Eq, Show)

type Camera = Camera'

type instance GetTableName (Camera') = "cameras"
type instance GetModelByTableName "cameras" = Camera


instance IHP.ModelSupport.Table (Camera') where
    tableName = "cameras"
    columnNames = ["id","slug","name","rtsp_url","rtsp_template","rtsp_transport","host","port","username","password_enc","password_nonce","codec","rtsp_sub_url","rtsp_sub_template","use_substream_for_analysis","substream_codec","substream_width","substream_height","record_audio","analysis_fps","model_name","enabled","retention_hours","assigned_host","manual_assign","onvif_port","mgmt_proto","main_video_encoding","main_video_width","main_video_height","main_video_fps","main_video_bitrate_kbps","main_video_gov_length","sub_video_encoding","sub_video_width","sub_video_height","sub_video_fps","sub_video_bitrate_kbps","sub_video_gov_length","audio_encoding","audio_bitrate_kbps","audio_sample_rate_khz","created_at","updated_at"]
    primaryKeyColumnNames = ["id"]


