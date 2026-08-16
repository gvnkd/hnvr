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

module Generated.ActualTypes.Camera where

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

data Camera' = Camera {id :: (Id' "cameras"), slug :: Text, name :: Text, rtspUrl :: Text, rtspTransport :: Text, host :: (Maybe Text), username :: (Maybe Text), passwordEnc :: (Maybe (Binary ByteString)), passwordNonce :: (Maybe (Binary ByteString)), codec :: CodecKind, rtspSubUrl :: (Maybe Text), useSubstreamForAnalysis :: Bool, substreamCodec :: CodecKind, substreamWidth :: (Maybe Int), substreamHeight :: (Maybe Int), recordAudio :: Bool, analysisFps :: Int, modelName :: Text, enabled :: Bool, retentionHours :: Int, assignedHost :: (Maybe Text), manualAssign :: Bool, onvifPort :: (Maybe Int), mgmtProto :: Text, mainVideoEncoding :: (Maybe Text), mainVideoWidth :: (Maybe Int), mainVideoHeight :: (Maybe Int), mainVideoFps :: (Maybe Int), mainVideoBitrateKbps :: (Maybe Int), mainVideoGovLength :: (Maybe Int), subVideoEncoding :: (Maybe Text), subVideoWidth :: (Maybe Int), subVideoHeight :: (Maybe Int), subVideoFps :: (Maybe Int), subVideoBitrateKbps :: (Maybe Int), subVideoGovLength :: (Maybe Int), audioEncoding :: (Maybe Text), audioBitrateKbps :: (Maybe Int), audioSampleRateKhz :: (Maybe Int), createdAt :: UTCTime, updatedAt :: UTCTime, meta :: MetaBag} deriving (Eq, Show)

type Camera = Camera'

type instance GetTableName (Camera') = "cameras"

type instance GetModelByTableName "cameras" = Camera

instance IHP.ModelSupport.Table (Camera') where
  tableName = "cameras"
  columnNames = ["id", "slug", "name", "rtsp_url", "rtsp_transport", "host", "username", "password_enc", "password_nonce", "codec", "rtsp_sub_url", "use_substream_for_analysis", "substream_codec", "substream_width", "substream_height", "record_audio", "analysis_fps", "model_name", "enabled", "retention_hours", "assigned_host", "manual_assign", "onvif_port", "mgmt_proto", "main_video_encoding", "main_video_width", "main_video_height", "main_video_fps", "main_video_bitrate_kbps", "main_video_gov_length", "sub_video_encoding", "sub_video_width", "sub_video_height", "sub_video_fps", "sub_video_bitrate_kbps", "sub_video_gov_length", "audio_encoding", "audio_bitrate_kbps", "audio_sample_rate_khz", "created_at", "updated_at"]
  primaryKeyColumnNames = ["id"]
