{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Fragmented-MP4 box parser.
--
-- Watches @moof@\/@mdat@ boundaries on the recording ffmpeg's stdout pipe
-- and yields one 'MediaFragment' per moof+mdat pair. The very first chunk
-- of the stream (the @ftyp@ + @moov@ init segment) is emitted once as an
-- 'InitFragment' before the first media fragment.
--
-- The parser is a /pure Mealy machine/: 'feed' takes the current state and
-- a chunk and returns the new state plus any fragments that became
-- complete. This makes it trivial to test with QuickCheck (chunk
-- boundaries don't matter — see @tests/Fmp4Spec@).
--
-- The fragments are HLS-ready out of the box thanks to the
-- @+frag_keyframe+empty_moov+default_base_moof+omit_tfhd_offset@ flags at
-- the ffmpeg side.
module Hnvr.Capture.Fmp4
  ( -- * State machine
    Fmp4State,
    initial,
    feed,
    finish,

    -- * Output
    Fragment (..),
  )
where

import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Word (Word32, Word64)

-- | One parsed fragment emitted by the segmenter.
data Fragment
  = -- | @ftyp@ + @moov@ + other pre-moof boxes. Emitted once, before the
    -- first 'MediaFragment'. The CaptureWorker may publish this to S3 as
    -- @<slug>/init.mp4@ for HLS clients, or drop it if HLS init is rendered
    -- server-side.
    InitFragment !ByteString
  | -- | One @moof@ + @mdat@ pair = one 1-second recording fragment.
    MediaFragment !ByteString
  deriving stock (Eq, Show)

-- | Internal state of the streaming parser.
data Fmp4State = Fmp4State
  { -- Bytes accumulated for the init segment (before first moof seen).
    fsInitAcc :: !ByteString,
    -- Bytes accumulated for the in-flight media fragment (Nothing = no
    -- moof currently open).
    fsFragAcc :: !(Maybe ByteString),
    -- Bytes received but not yet parseable as a complete box.
    fsUnparsed :: !ByteString
  }
  deriving stock (Eq, Show)

-- | Empty state. Begin every ffmpeg stdout reader with this.
initial :: Fmp4State
initial =
  Fmp4State
    { fsInitAcc = B.empty,
      fsFragAcc = Nothing,
      fsUnparsed = B.empty
    }

-- | Feed a chunk of bytes from the ffmpeg stdout pipe. Returns any
-- fragments that became complete plus the new state. Chunk boundaries
-- are arbitrary — feeding the same bytes in different chunkings yields
-- the same fragments.
feed :: Fmp4State -> ByteString -> ([Fragment], Fmp4State)
feed st0 chunk = go (st0 {fsUnparsed = fsUnparsed st0 <> chunk}) []
  where
    go !st !acc =
      case parseBox (fsUnparsed st) of
        Nothing -> (reverse acc, st)
        Just (typ, b, rest) ->
          let (newFrags, st') = handleBox typ b (st {fsUnparsed = rest})
           in go st' (reverse newFrags ++ acc)

-- | Flush at EOF. Returns any partial 'MediaFragment' still open. The init
-- segment is already emitted in steady state by the time EOF arrives, so
-- we don't double-flush it.
finish :: Fmp4State -> Maybe Fragment
finish = fmap MediaFragment . fsFragAcc

-- | Dispatch a single complete box: append to whichever accumulator is
-- active, and emit fragments at moof→mdat completion boundaries.
handleBox :: ByteString -> ByteString -> Fmp4State -> ([Fragment], Fmp4State)
handleBox typ bytes st
  | typ == "moof" =
      -- New fragment starts. Flush the init accumulator if non-empty.
      let initFrags =
            [InitFragment (fsInitAcc st) | not (B.null (fsInitAcc st))]
       in (initFrags, st {fsInitAcc = B.empty, fsFragAcc = Just bytes})
  | typ == "mdat" =
      case fsFragAcc st of
        Nothing ->
          -- Stray mdat without a moof (shouldn't happen with our movflags).
          -- Be defensive: treat as init.
          ([], st {fsInitAcc = fsInitAcc st <> bytes})
        Just fragBytes ->
          -- Complete fragment: moof + mdat.
          ([MediaFragment (fragBytes <> bytes)], st {fsFragAcc = Nothing})
  | otherwise =
      -- styp / sidx / free / skip / uuid / etc. Append to whichever
      -- accumulator is active (init before first moof, fragment after).
      case fsFragAcc st of
        Just fb -> ([], st {fsFragAcc = Just (fb <> bytes)})
        Nothing -> ([], st {fsInitAcc = fsInitAcc st <> bytes})

-- | Try to parse one complete ISO-BMFF box off the front of the buffer.
-- Returns the 4-byte type, the full box bytes (header + payload), and the
-- leftover buffer. Returns 'Nothing' if not enough bytes are available.
parseBox :: ByteString -> Maybe (ByteString, ByteString, ByteString)
parseBox buf
  | B.length buf < 8 = Nothing
  | otherwise =
      let size = readBE32 (B.take 4 buf)
          typ = B.take 4 (B.drop 4 buf)
       in case size of
            0 ->
              -- size==0 means "box extends to end of stream" (rare in our flow).
              Just (typ, buf, B.empty)
            1 ->
              -- Extended size: 64-bit size follows the 8-byte header.
              if B.length buf < 16
                then Nothing
                else
                  let extSize = fromIntegral (readBE64 (B.take 8 (B.drop 8 buf))) :: Int
                   in if B.length buf < extSize
                        then Nothing
                        else Just (typ, B.take extSize buf, B.drop extSize buf)
            _ ->
              let n = fromIntegral size :: Int
               in if B.length buf < n
                    then Nothing
                    else Just (typ, B.take n buf, B.drop n buf)

-- | Big-endian uint32 from a 4-byte buffer (assumes length >= 4).
readBE32 :: ByteString -> Word32
readBE32 = B.foldl step 0 . B.take 4
  where
    step !acc w = (acc `shiftL` 8) .|. fromIntegral w

-- | Big-endian uint64 from an 8-byte buffer (assumes length >= 8).
readBE64 :: ByteString -> Word64
readBE64 = B.foldl step 0 . B.take 8
  where
    step !acc w = (acc `shiftL` 8) .|. fromIntegral w
