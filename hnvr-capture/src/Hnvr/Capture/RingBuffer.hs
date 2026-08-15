{-# LANGUAGE DerivingStrategies #-}

-- | Per-camera rolling buffer of recent fMP4 fragments, backing the
-- event-clip recorder (separated event video store).
--
-- The capture worker pushes every video fragment (and the latest init
-- segment) into the buffer as it arrives; the clip recorder
-- ("Hnvr.Node.ClipRecorder", hnvr-web) reads windows out of it when a
-- rule with clip recording enabled fires. The buffer is pure and
-- time-bounded: entries older than the configured window are pruned on
-- every push, so a 15 s window on a camera emitting 2 fragments/s
-- holds at most ~30 entries regardless of uptime.
--
-- Fragments start on keyframes (ffmpeg @+frag_keyframe@), so any
-- contiguous run of entries plus the init segment is directly playable
-- — clip assembly is byte concatenation / playlisting, no re-encode.
module Hnvr.Capture.RingBuffer
  ( -- * Types
    RingEntry (..),
    RingBuffer,

    -- * Construction
    empty,

    -- * Mutation (pure)
    push,
    setInit,

    -- * Queries
    window,
    entries,
    initBytes,
    windowSec,
  )
where

import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.Sequence (Seq (..))
import qualified Data.Sequence as Seq
import Data.Time.Clock (UTCTime, addUTCTime)

-- | One buffered media fragment. 'reStart' is the wall-clock arrival
-- time (same clock 'Hnvr.Core.Segment' rows and CV events use), so
-- clip windows line up with event timestamps directly.
data RingEntry = RingEntry
  { reStart :: !UTCTime,
    reBytes :: !ByteString
  }
  deriving stock (Eq, Show)

-- | Time-bounded fragment buffer. Entries are kept in ascending
-- 'reStart' order; 'rbInit' is the most recent init segment emitted by
-- ffmpeg (re-sent on every encoder restart).
data RingBuffer = RingBuffer
  { rbWindowSec :: !Int,
    rbInit :: !(Maybe ByteString),
    rbEntries :: !(Seq RingEntry)
  }
  deriving stock (Eq, Show)

-- | An empty buffer retaining the last @windowSecs@ seconds of
-- fragments. Callers should size this at
-- @max clip_preroll_sec + max clip_postroll_sec + margin@ across the
-- camera's clip-enabled rules (the clip recorder snapshots on open and
-- on every extension, so a modest margin suffices).
empty :: Int -> RingBuffer
empty windowSecs = RingBuffer windowSecs Nothing Seq.empty

-- | Append a fragment and prune entries that fell out of the window.
-- Pruning is keyed off the NEW entry's start time (the freshest clock
-- reading available), so the buffer self-limits even if 'getCurrentTime'
-- jitter reorders timestamps slightly.
push :: UTCTime -> ByteString -> RingBuffer -> RingBuffer
push ts bs rb =
  let cutoff = addUTCTime (negate (fromIntegral (rbWindowSec rb))) ts
      kept = Seq.dropWhileL (\e -> reStart e < cutoff) (rbEntries rb)
   in rb {rbEntries = kept :|> RingEntry ts bs}

-- | Record the latest init segment bytes.
setInit :: ByteString -> RingBuffer -> RingBuffer
setInit bs rb = rb {rbInit = Just bs}

-- | Entries whose 'reStart' lies in @[from, to]@, ascending.
window :: UTCTime -> UTCTime -> RingBuffer -> [RingEntry]
window from to =
  toList . Seq.filter (\e -> reStart e >= from && reStart e <= to) . rbEntries

-- | All buffered entries, ascending. Mostly for tests/debug.
entries :: RingBuffer -> [RingEntry]
entries = toList . rbEntries

-- | The latest init segment, if ffmpeg has emitted one since boot.
initBytes :: RingBuffer -> Maybe ByteString
initBytes = rbInit

-- | Configured retention window of the buffer, in seconds.
windowSec :: RingBuffer -> Int
windowSec = rbWindowSec
