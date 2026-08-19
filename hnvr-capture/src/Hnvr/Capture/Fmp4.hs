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
  | -- | One @moof@ + @mdat@ pair = one 1-second recording fragment. The
    -- 'Word64' is the @baseMediaDecodeTime@ from the first @tfdt@ box
    -- inside the moof (0 if not found). Track-timescale units; useful
    -- for media-time alignment in Phase 3 CV; the worker currently uses
    -- wall-clock hold-back for @sEnd@, so this field is informational.
    -- The 'Bool' is True when the moof contains 2+ @traf@ boxes, i.e.
    -- the fragment carries a muxed audio track alongside the video
    -- (ffmpeg 7.x writes one moof with one traf per track). It drives
    -- the @segments.has_audio@ column; a video-only camera's moofs have
    -- exactly one traf.
    MediaFragment !Word64 !Bool !ByteString
  deriving stock (Eq, Show)

-- | Internal state of the streaming parser.
data Fmp4State = Fmp4State
  { -- Bytes accumulated for the init segment (before first moof seen).
    fsInitAcc :: !ByteString,
    -- Bytes accumulated for the in-flight media fragment (Nothing = no
    -- moof currently open). The 'Word64' is the @baseMediaDecodeTime@
    -- scraped from the first @tfdt@ in the moof at the time the moof
    -- opened — captured here so we don't have to re-parse the moof
    -- payload when the matching mdat arrives. The 'Bool' is the moof's
    -- @traf@-count > 1 (audio track present), captured the same way.
    fsFragAcc :: !(Maybe (Word64, Bool, ByteString)),
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
finish st = case fsFragAcc st of
  Nothing -> Nothing
  Just (tfdt, hasAudio, bs) -> Just (MediaFragment tfdt hasAudio bs)

-- | Dispatch a single complete box: append to whichever accumulator is
-- active, and emit fragments at moof→mdat completion boundaries.
handleBox :: ByteString -> ByteString -> Fmp4State -> ([Fragment], Fmp4State)
handleBox typ bytes st
  | typ == "moof" =
      -- New fragment starts. Flush the init accumulator if non-empty.
      let initFrags =
            [InitFragment (fsInitAcc st) | not (B.null (fsInitAcc st))]
          tfdt = findTfdt bytes
          hasAudio = countChildren "traf" (boxPayload bytes) > 1
       in (initFrags, st {fsInitAcc = B.empty, fsFragAcc = Just (tfdt, hasAudio, bytes)})
  | typ == "mdat" =
      case fsFragAcc st of
        Nothing ->
          -- Stray mdat without a moof (shouldn't happen with our movflags).
          -- Be defensive: treat as init.
          ([], st {fsInitAcc = fsInitAcc st <> bytes})
        Just (tfdt, hasAudio, fragBytes) ->
          -- Complete fragment: moof + mdat.
          ([MediaFragment tfdt hasAudio (fragBytes <> bytes)], st {fsFragAcc = Nothing})
  | otherwise =
      -- styp / sidx / free / skip / uuid / etc. Append to whichever
      -- accumulator is active (init before first moof, fragment after).
      case fsFragAcc st of
        Just (tfdt, hasAudio, fb) -> ([], st {fsFragAcc = Just (tfdt, hasAudio, fb <> bytes)})
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

-- | Walk a moof box's children looking for the first @tfdt@. Returns 0
-- if not found (defensive — every well-formed fragmented track has one,
-- but we never want the segmenter to crash on a malformed stream).
--
-- Structure (ISO/IEC 14496-12):
--
-- @
-- moof
-- └── traf
--     ├── tfhd  (ignored here)
--     └── tfdt  (FullBox: 1B version + 3B flags, then 4-or-8 byte baseMediaDecodeTime)
-- @
findTfdt :: ByteString -> Word64
findTfdt moof = case findChild "traf" (boxPayload moof) of
  Just traf -> case findChild "tfdt" (boxPayload traf) of
    Just tfdt -> parseTfdt (boxPayload tfdt)
    Nothing -> 0
  Nothing -> 0

-- | Strip the 8-byte box header, returning the payload. Assumes the
-- input is a single complete box.
boxPayload :: ByteString -> ByteString
boxPayload buf =
  let size = readBE32 (B.take 4 buf)
   in case size of
        1 ->
          -- Extended size: payload starts after the 16-byte header.
          B.drop 16 buf
        _ ->
          -- Standard 8-byte header.
          B.drop 8 buf

-- | Iterate the children of a parent box payload, returning the first
-- child whose 4-byte type matches.
findChild :: ByteString -> ByteString -> Maybe ByteString
findChild want = go
  where
    go buf
      | B.length buf < 8 = Nothing
      | otherwise =
          let size = readBE32 (B.take 4 buf)
              typ = B.take 4 (B.drop 4 buf)
           in case size of
                0 -> if typ == want then Just buf else Nothing
                1 ->
                  if B.length buf < 16
                    then Nothing
                    else
                      let extSize = fromIntegral (readBE64 (B.take 8 (B.drop 8 buf))) :: Int
                       in if B.length buf < extSize
                            then Nothing
                            else if typ == want then Just buf else go (B.drop extSize buf)
                _ ->
                  let n = fromIntegral size :: Int
                   in if B.length buf < n
                        then Nothing
                        else if typ == want then Just buf else go (B.drop n buf)

-- | Count the children of a parent box payload whose 4-byte type
-- matches. Same box-walking rules as 'findChild'.
countChildren :: ByteString -> ByteString -> Int
countChildren want = go 0
  where
    go !n buf
      | B.length buf < 8 = n
      | otherwise =
          let size = readBE32 (B.take 4 buf)
              typ = B.take 4 (B.drop 4 buf)
           in case size of
                0 -> if typ == want then n + 1 else n
                1 ->
                  if B.length buf < 16
                    then n
                    else
                      let extSize = fromIntegral (readBE64 (B.take 8 (B.drop 8 buf))) :: Int
                       in if B.length buf < extSize
                            then n
                            else go (if typ == want then n + 1 else n) (B.drop extSize buf)
                _ ->
                  let bsize = fromIntegral size :: Int
                   in if B.length buf < bsize
                        then n
                        else go (if typ == want then n + 1 else n) (B.drop bsize buf)

-- | Parse the body of a tfdt box (after the 8-byte box header). The body
-- is a FullBox: 1-byte version, 3-byte flags, then the timestamp.
-- Version 1 → 8-byte Word64; version 0 → 4-byte Word32 zero-extended.
parseTfdt :: ByteString -> Word64
parseTfdt body
  | B.length body < 4 = 0
  | otherwise =
      let version = B.index body 0
       in if version == 1
            then
              if B.length body >= 12
                then readBE64 (B.take 8 (B.drop 4 body))
                else 0
            else
              if B.length body >= 8
                then fromIntegral (readBE32 (B.take 4 (B.drop 4 body)))
                else 0
