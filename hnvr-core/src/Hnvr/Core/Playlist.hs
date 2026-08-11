{-# LANGUAGE OverloadedStrings #-}

-- | Pure HLS VOD playlist rendering for archive playback.
--
-- fMP4 HLS requires @EXT-X-VERSION:6@ and a single @EXT-X-MAP@ pointing
-- at the init segment (ftyp+moov), which the capture worker uploads
-- once per camera as @\<slug\>/init.mp4@. Segment URLs are presigned
-- S3 GETs; presigning is IO and stays in hnvr-web — this module renders
-- from already-resolved URLs so it is cabal-testable (pitfall #14
-- extraction pattern).
module Hnvr.Core.Playlist
  ( renderVodPlaylist,
    renderEmptyPlaylist,
  )
where

import Data.Text (Text)
import qualified Data.Text as T
import Numeric (showFFloat)

-- | Render a VOD m3u8. First argument is the presigned init.mp4 URL;
-- entries are @(durationSeconds, presignedSegmentUrl)@ in play order.
-- @EXT-X-TARGETDURATION@ is the ceiling of the longest entry (min 1),
-- per RFC 8216 §4.3.3.1.
renderVodPlaylist :: Text -> [(Double, Text)] -> Text
renderVodPlaylist initUrl entries =
  T.unlines $
    [ "#EXTM3U",
      "#EXT-X-VERSION:6",
      "#EXT-X-TARGETDURATION:" <> tshow targetDuration,
      "#EXT-X-PLAYLIST-TYPE:VOD",
      "#EXT-X-MAP:URI=\"" <> initUrl <> "\""
    ]
      <> concatMap entry entries
      <> ["#EXT-X-ENDLIST"]
  where
    targetDuration = max 1 (ceiling (maximum (0 : map fst entries)) :: Int)
    entry (dur, url) = ["#EXTINF:" <> T.pack (showFFloat (Just 3) dur "") <> ",", url]
    tshow = T.pack . show

-- | Playlist with no segments (S3 unconfigured, or empty window).
-- No @EXT-X-MAP@ — there is nothing to play.
renderEmptyPlaylist :: Text
renderEmptyPlaylist =
  T.unlines
    [ "#EXTM3U",
      "#EXT-X-VERSION:6",
      "#EXT-X-TARGETDURATION:1",
      "#EXT-X-PLAYLIST-TYPE:VOD",
      "#EXT-X-ENDLIST"
    ]
