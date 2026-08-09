{-# LANGUAGE OverloadedStrings #-}

-- | Time helpers used to derive SeaweedFS object keys and log stamps.
--
-- All formatting is UTC (camera segments are addressed by wall-clock UTC;
-- timezone display is the UI's concern).
module Hnvr.Core.Time
  ( formatSegmentObjectKey,
    formatSegmentObjectKeyMs,
    formatSegmentDir,
    formatYmdHms,
    formatYmdHmsMs,
  )
where

import Data.Fixed (E3, Fixed (..))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, utctDayTime)
import Data.Time.Format (defaultTimeLocale, formatTime)

-- | @cam-196/2026-08-07/14-30-15.mp4@ — full S3 object key for a 1-second
-- segment. The slug already carries the @cam-@@ prefix. Use this only when
-- the caller guarantees one fragment per wall-clock second (e.g. audio
-- fragments at exactly 1s boundaries); for video fragments, prefer
-- 'formatSegmentObjectKeyMs' because HEVC cameras often emit 2+ fragments
-- per second.
formatSegmentObjectKey :: Text -> UTCTime -> Text
formatSegmentObjectKey slug ts =
  slug <> "/" <> formatYmdHms ts <> ".mp4"

-- | @cam-196/2026-08-07/14-30-15.734.mp4@ — millisecond precision to avoid
-- collisions when the camera emits multiple fMP4 fragments within the same
-- wall-clock second (HEVC keyframe-aligned fragmentation on cam-196).
formatSegmentObjectKeyMs :: Text -> UTCTime -> Text
formatSegmentObjectKeyMs slug ts =
  slug <> "/" <> formatYmdHmsMs ts <> ".mp4"

-- | @cam-196/2026-08-07@ — directory prefix; useful for @ListObjectsV2@
-- queries during retention sweep.
formatSegmentDir :: Text -> UTCTime -> Text
formatSegmentDir slug ts =
  slug <> "/" <> T.pack (formatTime defaultTimeLocale "%Y-%m-%d" ts)

-- | @2026-08-07/14-30-15@ — ISO-ish, filesystem-safe (no colon).
formatYmdHms :: UTCTime -> Text
formatYmdHms =
  T.pack . formatTime defaultTimeLocale "%Y-%m-%d/%H-%M-%S"

-- | @2026-08-07/14-30-15.734@ — milliseconds appended.
formatYmdHmsMs :: UTCTime -> Text
formatYmdHmsMs ts =
  T.pack (formatTime defaultTimeLocale "%Y-%m-%d/%H-%M-%S" ts)
    <> "."
    <> T.pack (pad3 (msInt `mod` 1000))
  where
    msFixed :: Fixed E3
    msFixed = realToFrac (utctDayTime ts)
    MkFixed msInt = msFixed
    pad3 n
      | n < 10 = "00" ++ show n
      | n < 100 = "0" ++ show n
      | otherwise = show n
