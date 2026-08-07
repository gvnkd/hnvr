-- | ffmpeg subprocess management.
--
-- Two ffmpeg invocations per camera (record main + analyze sub), plus an
-- optional third for muxed audio. All flags are documented in
-- @design_docs/03-capture-and-storage.md@.
--
-- Implementation lands in Phase 1. Uses @typed-process@ for safe subprocess
-- construction. The CaptureWorker owns the process handles; on exit
-- (graceful or otherwise) it must @waitForProcess@ to avoid zombies.
module Hnvr.Capture.Ffmpeg () where
