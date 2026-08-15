{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | S3 object layout for event video clips (separated event video
-- store). A clip is a self-contained fMP4 mini-archive under one
-- prefix:
--
-- @
-- \<slug\>/clips/\<YYYY-MM-DD/HH-MM-SS.mmm\>/init.mp4
-- \<slug\>/clips/\<YYYY-MM-DD/HH-MM-SS.mmm\>/\<HH-MM-SS.mmm\>.mp4 …
-- @
--
-- The prefix timestamp is the clip's start (first event ts minus the
-- rule's pre-roll). Fragment files reuse the main-recording naming
-- ('formatYmdHmsMs') so prefix-level S3 listing and deletion treat a
-- clip exactly like a camera day-directory — the retention sweep and
-- tombstone purge can delete by prefix without knowing clip internals.
module Hnvr.Core.Clip
  ( clipPrefix,
    clipInitKey,
    clipFragKey,
    clipDurationSec,
    playlistDurations,
  )
where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, diffUTCTime)
import Hnvr.Core.Time (formatYmdHmsMs)
import Text.Read (readMaybe)

-- | S3 prefix owning all objects of one clip. Ends with a trailing
-- slash so @listObjects prefix@ and prefix DELETE stay simple.
clipPrefix :: Text -> UTCTime -> Text
clipPrefix slug startedAt = slug <> "/clips/" <> formatYmdHmsMs startedAt <> "/"

-- | Object key of the clip's init segment.
clipInitKey :: Text -> Text
clipInitKey prefix = prefix <> "init.mp4"

-- | Object key of one fragment inside the clip, named by the
-- fragment's wall-clock time-of-day (millisecond precision — HEVC
-- cameras emit 2+ fragments per second, pitfall #25). The date part
-- is already carried by the prefix.
clipFragKey :: Text -> UTCTime -> Text
clipFragKey prefix fragStart = prefix <> hmsMs fragStart <> ".mp4"
  where
    hmsMs ts = T.drop 11 (formatYmdHmsMs ts)

-- | Whole-second duration between clip start and close deadline.
-- Floor (not round) so the reported duration never overstates the
-- stored footage.
clipDurationSec :: UTCTime -> UTCTime -> Int
clipDurationSec startedAt deadline = floor (diffUTCTime deadline startedAt)

-- | Per-fragment durations (seconds) for an HLS VOD playlist, derived
-- from the time-of-day embedded in each fragment's object key
-- (@HH-MM-SS.mmm.mp4@). Input must be the clip's fragment keys in
-- play order (S3 LIST returns them lexically sorted, which equals
-- chronological order within one day). Duration of a fragment = next
-- fragment's start minus its own; the last fragment (and any
-- non-monotonic successor, e.g. a midnight-crossing clip) gets
-- 'lastFragFallbackSec'. Keys that don't parse are skipped.
playlistDurations :: [Text] -> [(Text, Double)]
playlistDurations keys =
  [ (k, dur)
  | ((k, Just t), mNext) <- zip parsed nexts,
    let dur = case mNext of
          Just nxt | nxt > t -> realToFrac (nxt - t)
          _ -> lastFragFallbackSec
  ]
  where
    parsed = zip keys (map parseFragTod keys)
    nexts = drop 1 (map snd parsed) ++ [Nothing]

-- | Assumed duration of the final fragment (no successor to diff
-- against). Matches the recorder's 1 s nominal fragment cadence.
lastFragFallbackSec :: Double
lastFragFallbackSec = 1.0

-- | Parse @HH-MM-SS.mmm@ (the part after the last slash, minus the
-- @.mp4@ extension) into seconds since midnight.
parseFragTod :: Text -> Maybe Double
parseFragTod key = do
  let file = T.takeWhileEnd (/= '/') key
  base <- T.stripSuffix ".mp4" file
  case T.splitOn "-" base of
    [hh, mm, ssMs] -> do
      h <- readT hh
      m <- readT mm
      s <- readT ssMs
      pure (h * 3600 + m * 60 + s)
    _ -> Nothing
  where
    readT :: Text -> Maybe Double
    readT = readMaybe . T.unpack
