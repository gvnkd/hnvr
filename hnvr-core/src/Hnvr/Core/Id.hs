{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | Domain identifiers used throughout HNVR.
--
-- Defined here so that all sublibraries (capture, cv, ptz, storage, web) share
-- a single canonical type for each ID, avoiding accidental String\/Text mixups
-- at boundaries.
module Hnvr.Core.Id
  ( CameraId (..),
    RuleId (..),
    TrackId (..),
    HostId (..),
    Sha256 (..),
    sha256ToHex,
    sha256FromHex,
  )
where

import Control.Monad (guard)
import Data.Aeson (FromJSON (..), ToJSON (..), Value (..), withText)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Char (digitToInt, isHexDigit)
import Data.String (IsString)
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import Numeric (showHex)

-- | Unique identifier for a configured camera. Stable across renames.
newtype CameraId = CameraId {unCameraId :: UUID}
  deriving newtype
    ( Eq,
      Ord,
      Show,
      FromJSON,
      ToJSON
    )

-- | Unique identifier for a CV rule (line-cross / zone-intrusion).
newtype RuleId = RuleId {unRuleId :: UUID}
  deriving newtype
    ( Eq,
      Ord,
      Show,
      FromJSON,
      ToJSON
    )

-- | Per-camera tracker ID assigned by SORT. Resets on tracker restart.
newtype TrackId = TrackId {unTrackId :: Int}
  deriving newtype
    ( Eq,
      Ord,
      Show,
      FromJSON,
      ToJSON,
      Num,
      Enum,
      Real,
      Integral
    )

-- | Our own NixOS host identifier (e.g. @hnvr-1@, @hnvr-2@).
newtype HostId = HostId {unHostId :: Text}
  deriving newtype
    ( Eq,
      Ord,
      Show,
      FromJSON,
      ToJSON,
      IsString,
      Semigroup,
      Monoid
    )

-- | SHA-256 digest of an fMP4 segment, used for SeaweedFS object integrity.
--
-- Stored as raw 32 bytes. JSON serialization is hex-encoded lowercase
-- (64 chars), matching the @x-amz-meta-sha256@ header convention.
newtype Sha256 = Sha256 {unSha256 :: ByteString}
  deriving newtype
    ( Eq,
      Ord,
      Show
    )

-- | Hex-encode a 'Sha256' as 64 lowercase chars.
sha256ToHex :: Sha256 -> Text
sha256ToHex (Sha256 bs) =
  T.pack $ concatMap (pad . flip showHex "") $ B.unpack bs
  where
    pad s@[_] = '0' : s
    pad s = s

-- | Parse a 64-char lowercase (or uppercase) hex string into a 'Sha256'.
-- Returns 'Nothing' on wrong length or non-hex char.
sha256FromHex :: Text -> Maybe Sha256
sha256FromHex t = do
  let s = T.unpack t
  guard (length s == 64)
  ws <- traverse hexPair (pairsOf s)
  guard (length ws == 32)
  pure (Sha256 (B.pack ws))
  where
    pairsOf [] = []
    pairsOf (a : b : rest) = (a, b) : pairsOf rest
    pairsOf _ = []
    hexPair (h, l) = do
      hv <- hexVal h
      lv <- hexVal l
      Just (fromIntegral (hv * 16 + lv))
    hexVal :: Char -> Maybe Int
    hexVal c
      | isHexDigit c = Just (digitToInt c)
      | otherwise = Nothing

instance ToJSON Sha256 where
  toJSON = String . sha256ToHex

instance FromJSON Sha256 where
  parseJSON = withText "Sha256" $ \t -> case sha256FromHex t of
    Just s -> pure s
    Nothing -> fail "Sha256 must be 64 hex chars"
