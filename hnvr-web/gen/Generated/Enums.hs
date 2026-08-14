-- This file is auto generated and will be overriden regulary. Please edit `Application/Schema.sql` to change the Types\n"
module Generated.Enums where
import CorePrelude
import IHP.ModelSupport
import Database.PostgreSQL.Simple
import Database.PostgreSQL.Simple.FromField hiding (Field, name)
import Database.PostgreSQL.Simple.ToField hiding (Field)
import qualified IHP.Controller.Param
import Data.Default
import qualified IHP.QueryBuilder as QueryBuilder
import qualified Data.String.Conversions
import qualified Data.Text.Encoding
import qualified Control.DeepSeq as DeepSeq
import qualified Hasql.Encoders
import qualified Hasql.Decoders
import qualified Hasql.Implicits.Encoders
import qualified Hasql.Mapping.IsScalar as Mapping
import qualified Data.HashMap.Strict as HashMap
data CodecKind = H264 | Hevc | Unknown deriving (Eq, Show, Read, Enum, Bounded, Ord)
instance FromField CodecKind where
    fromField field (Just value) | value == (Data.Text.Encoding.encodeUtf8 "h264") = pure H264
    fromField field (Just value) | value == (Data.Text.Encoding.encodeUtf8 "hevc") = pure Hevc
    fromField field (Just value) | value == (Data.Text.Encoding.encodeUtf8 "unknown") = pure Unknown
    fromField field (Just value) = returnError ConversionFailed field ("Unexpected value for enum value. Got: " <> Data.String.Conversions.cs value)
    fromField field Nothing = returnError UnexpectedNull field "Unexpected null for enum value"
instance Default CodecKind where def = H264
instance ToField CodecKind where
    toField H264 = toField ("h264" :: Text)
    toField Hevc = toField ("hevc" :: Text)
    toField Unknown = toField ("unknown" :: Text)
instance InputValue CodecKind where
    inputValue H264 = "h264" :: Text
    inputValue Hevc = "hevc" :: Text
    inputValue Unknown = "unknown" :: Text
instance DeepSeq.NFData CodecKind where rnf a = seq a ()
instance IHP.Controller.Param.ParamReader CodecKind where readParameter = IHP.Controller.Param.enumParamReader; readParameterJSON = IHP.Controller.Param.enumParamReaderJSON
textToEnumCodecKindMap :: HashMap.HashMap Text CodecKind
textToEnumCodecKindMap = HashMap.fromList [("h264", H264), ("hevc", Hevc), ("unknown", Unknown)]
textToEnumCodecKind :: Text -> Maybe CodecKind
textToEnumCodecKind t = HashMap.lookup t textToEnumCodecKindMap
instance Hasql.Implicits.Encoders.DefaultParamEncoder CodecKind where
    defaultParam = Hasql.Encoders.nonNullable (Hasql.Encoders.enum (Just "public") "codec_kind" inputValue)
instance Hasql.Implicits.Encoders.DefaultParamEncoder (Maybe CodecKind) where
    defaultParam = Hasql.Encoders.nullable (Hasql.Encoders.enum (Just "public") "codec_kind" inputValue)
instance Hasql.Implicits.Encoders.DefaultParamEncoder [CodecKind] where
    defaultParam = Hasql.Encoders.nonNullable $ Hasql.Encoders.foldableArray $ Hasql.Encoders.nonNullable (Hasql.Encoders.enum (Just "public") "codec_kind" inputValue)
instance Mapping.IsScalar CodecKind where
    encoder = Hasql.Encoders.enum (Just "public") "codec_kind" inputValue
    decoder = Hasql.Decoders.enum (Just "public") "codec_kind" textToEnumCodecKind


data RuleKind = LineCross | RuleKindZoneEnter | RuleKindZoneExit | RuleKindZoneInside deriving (Eq, Show, Read, Enum, Bounded, Ord)
instance FromField RuleKind where
    fromField field (Just value) | value == (Data.Text.Encoding.encodeUtf8 "line_cross") = pure LineCross
    fromField field (Just value) | value == (Data.Text.Encoding.encodeUtf8 "zone_enter") = pure RuleKindZoneEnter
    fromField field (Just value) | value == (Data.Text.Encoding.encodeUtf8 "zone_exit") = pure RuleKindZoneExit
    fromField field (Just value) | value == (Data.Text.Encoding.encodeUtf8 "zone_inside") = pure RuleKindZoneInside
    fromField field (Just value) = returnError ConversionFailed field ("Unexpected value for enum value. Got: " <> Data.String.Conversions.cs value)
    fromField field Nothing = returnError UnexpectedNull field "Unexpected null for enum value"
instance Default RuleKind where def = LineCross
instance ToField RuleKind where
    toField LineCross = toField ("line_cross" :: Text)
    toField RuleKindZoneEnter = toField ("zone_enter" :: Text)
    toField RuleKindZoneExit = toField ("zone_exit" :: Text)
    toField RuleKindZoneInside = toField ("zone_inside" :: Text)
instance InputValue RuleKind where
    inputValue LineCross = "line_cross" :: Text
    inputValue RuleKindZoneEnter = "zone_enter" :: Text
    inputValue RuleKindZoneExit = "zone_exit" :: Text
    inputValue RuleKindZoneInside = "zone_inside" :: Text
instance DeepSeq.NFData RuleKind where rnf a = seq a ()
instance IHP.Controller.Param.ParamReader RuleKind where readParameter = IHP.Controller.Param.enumParamReader; readParameterJSON = IHP.Controller.Param.enumParamReaderJSON
textToEnumRuleKindMap :: HashMap.HashMap Text RuleKind
textToEnumRuleKindMap = HashMap.fromList [("line_cross", LineCross), ("zone_enter", RuleKindZoneEnter), ("zone_exit", RuleKindZoneExit), ("zone_inside", RuleKindZoneInside)]
textToEnumRuleKind :: Text -> Maybe RuleKind
textToEnumRuleKind t = HashMap.lookup t textToEnumRuleKindMap
instance Hasql.Implicits.Encoders.DefaultParamEncoder RuleKind where
    defaultParam = Hasql.Encoders.nonNullable (Hasql.Encoders.enum (Just "public") "rule_kind" inputValue)
instance Hasql.Implicits.Encoders.DefaultParamEncoder (Maybe RuleKind) where
    defaultParam = Hasql.Encoders.nullable (Hasql.Encoders.enum (Just "public") "rule_kind" inputValue)
instance Hasql.Implicits.Encoders.DefaultParamEncoder [RuleKind] where
    defaultParam = Hasql.Encoders.nonNullable $ Hasql.Encoders.foldableArray $ Hasql.Encoders.nonNullable (Hasql.Encoders.enum (Just "public") "rule_kind" inputValue)
instance Mapping.IsScalar RuleKind where
    encoder = Hasql.Encoders.enum (Just "public") "rule_kind" inputValue
    decoder = Hasql.Decoders.enum (Just "public") "rule_kind" textToEnumRuleKind


data EventKind = LineCrossed | EventKindZoneEnter | EventKindZoneExit | EventKindZoneInside | TrackStart | TrackEnd | SegmentWritten | System deriving (Eq, Show, Read, Enum, Bounded, Ord)
instance FromField EventKind where
    fromField field (Just value) | value == (Data.Text.Encoding.encodeUtf8 "line_crossed") = pure LineCrossed
    fromField field (Just value) | value == (Data.Text.Encoding.encodeUtf8 "zone_enter") = pure EventKindZoneEnter
    fromField field (Just value) | value == (Data.Text.Encoding.encodeUtf8 "zone_exit") = pure EventKindZoneExit
    fromField field (Just value) | value == (Data.Text.Encoding.encodeUtf8 "zone_inside") = pure EventKindZoneInside
    fromField field (Just value) | value == (Data.Text.Encoding.encodeUtf8 "track_start") = pure TrackStart
    fromField field (Just value) | value == (Data.Text.Encoding.encodeUtf8 "track_end") = pure TrackEnd
    fromField field (Just value) | value == (Data.Text.Encoding.encodeUtf8 "segment_written") = pure SegmentWritten
    fromField field (Just value) | value == (Data.Text.Encoding.encodeUtf8 "system") = pure System
    fromField field (Just value) = returnError ConversionFailed field ("Unexpected value for enum value. Got: " <> Data.String.Conversions.cs value)
    fromField field Nothing = returnError UnexpectedNull field "Unexpected null for enum value"
instance Default EventKind where def = LineCrossed
instance ToField EventKind where
    toField LineCrossed = toField ("line_crossed" :: Text)
    toField EventKindZoneEnter = toField ("zone_enter" :: Text)
    toField EventKindZoneExit = toField ("zone_exit" :: Text)
    toField EventKindZoneInside = toField ("zone_inside" :: Text)
    toField TrackStart = toField ("track_start" :: Text)
    toField TrackEnd = toField ("track_end" :: Text)
    toField SegmentWritten = toField ("segment_written" :: Text)
    toField System = toField ("system" :: Text)
instance InputValue EventKind where
    inputValue LineCrossed = "line_crossed" :: Text
    inputValue EventKindZoneEnter = "zone_enter" :: Text
    inputValue EventKindZoneExit = "zone_exit" :: Text
    inputValue EventKindZoneInside = "zone_inside" :: Text
    inputValue TrackStart = "track_start" :: Text
    inputValue TrackEnd = "track_end" :: Text
    inputValue SegmentWritten = "segment_written" :: Text
    inputValue System = "system" :: Text
instance DeepSeq.NFData EventKind where rnf a = seq a ()
instance IHP.Controller.Param.ParamReader EventKind where readParameter = IHP.Controller.Param.enumParamReader; readParameterJSON = IHP.Controller.Param.enumParamReaderJSON
textToEnumEventKindMap :: HashMap.HashMap Text EventKind
textToEnumEventKindMap = HashMap.fromList [("line_crossed", LineCrossed), ("zone_enter", EventKindZoneEnter), ("zone_exit", EventKindZoneExit), ("zone_inside", EventKindZoneInside), ("track_start", TrackStart), ("track_end", TrackEnd), ("segment_written", SegmentWritten), ("system", System)]
textToEnumEventKind :: Text -> Maybe EventKind
textToEnumEventKind t = HashMap.lookup t textToEnumEventKindMap
instance Hasql.Implicits.Encoders.DefaultParamEncoder EventKind where
    defaultParam = Hasql.Encoders.nonNullable (Hasql.Encoders.enum (Just "public") "event_kind" inputValue)
instance Hasql.Implicits.Encoders.DefaultParamEncoder (Maybe EventKind) where
    defaultParam = Hasql.Encoders.nullable (Hasql.Encoders.enum (Just "public") "event_kind" inputValue)
instance Hasql.Implicits.Encoders.DefaultParamEncoder [EventKind] where
    defaultParam = Hasql.Encoders.nonNullable $ Hasql.Encoders.foldableArray $ Hasql.Encoders.nonNullable (Hasql.Encoders.enum (Just "public") "event_kind" inputValue)
instance Mapping.IsScalar EventKind where
    encoder = Hasql.Encoders.enum (Just "public") "event_kind" inputValue
    decoder = Hasql.Decoders.enum (Just "public") "event_kind" textToEnumEventKind

