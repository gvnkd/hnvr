-- | Fragmented-MP4 box parser (~80 LOC target).
--
-- Watches @moof@\/@tfdt@ boundaries on the recording ffmpeg's stdout pipe and
-- yields one @ByteString@ per 1-second fragment. The fragments are
-- HLS-compatible out of the box thanks to the @+frag_keyframe+empty_moov+
-- default_base_moof+omit_tfhd_offset@ flags at the ffmpeg side.
--
-- Implementation lands in Phase 1.
module Hnvr.Capture.Fmp4 () where
