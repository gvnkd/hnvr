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

