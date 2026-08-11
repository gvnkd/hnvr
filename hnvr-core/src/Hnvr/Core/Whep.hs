{-# LANGUAGE OverloadedStrings #-}

-- | WHEP path translation between the public-facing HNVR proxy path
-- and MediaMTX's internal WHEP endpoint.
--
-- WHEP is a 3-method flow:
--
--   * POST @/whep/<slug>@ with SDP offer → 201 with SDP answer + Location
--   * PATCH @/whep/<slug>/session/<id>@ with ICE restart SDP
--   * DELETE @/whep/<slug>/session/<id>@ to tear down
--
-- The browser-visible path lives under @/whep/@. MediaMTX expects the
-- path-name first, then the @whep@ sub-resource: @/<slug>/whep[…]@.
-- Translating in both directions lets the leader act as a transparent
-- reverse proxy without rewriting SDP bodies.
--
-- Originally extracted from @Hnvr.Web.WhepProxy@ so the translation
-- logic — a known historical bug source (pitfall #62: the naive
-- @"/" <> rest <> "/whep"@ append mangled session callbacks) — can be
-- property-tested independently of IHP / WAI.
module Hnvr.Core.Whep
  ( translatePath,
    translateBack,
  )
where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import Data.List (isPrefixOf, stripPrefix)

-- | Translate @/whep/<slug>[@/session/<id>]@ → @/<slug>/whep[@/session/<id>]@.
--
-- The naive @"/" <> rest <> "/whep"@ appended @/whep@ at the END, which
-- mangled session callbacks: @/whep/foo/session/123@ became
-- @/foo/session/123/whep@ (mediamtx 404). Split rest at the first @/@
-- so @/whep@ lands directly after the slug. Uses 'BSC.break' (Char-keyed)
-- since the file already standardises on the Char8 view of ByteStrings.
translatePath :: BS.ByteString -> BS.ByteString
translatePath p =
  let rest = BSC.drop (BSC.length "/whep/") p -- "<slug>[/session/<id>]"
      (slug, suffix) = BSC.break (== '/') rest
   in "/" <> slug <> "/whep" <> suffix

-- | Rewrite MediaMTX's @/<slug>/whep/session/<id>@ Location header back
-- to our public @/whep/<slug>/session/<id>@ form so the browser's next
-- PATCH/DELETE returns to us. Only rewrites Location / Content-Location.
--
-- Inverse of 'translatePath': a MediaMTX-absolute URL like
-- @http://host:8889/<slug>/whep/session/<id>@ or a path-only
-- @/<slug>/whep/session/<id>@ both become
-- @/whep/<slug>/session/<id>@ (path-only, so the browser uses its own
-- origin).
translateBack :: BS.ByteString -> BS.ByteString
translateBack v =
  let s = BSC.unpack v
      -- Strip scheme://host:port if present, then rewrite the path.
      pathOnly = case stripPrefix "http://" s of
        Just rest -> dropWhile (/= '/') rest
        Nothing -> case stripPrefix "https://" s of
          Just rest -> dropWhile (/= '/') rest
          Nothing -> s
   in case findWhepSuffix pathOnly of
        Just (before, after) ->
          -- 'after' starts with the "/whep" we located; drop it since
          -- we re-add "/whep" as the new prefix. Without this, the
          -- output was @/whep/<slug>/whep/session/<id>@ — a duplicate
          -- "/whep" in the middle of the path that 404'd at MediaMTX
          -- on the browser's PATCH/DELETE. (Pinned by WhepSpec.)
          BSC.pack ("/whep" <> before <> drop (length ("/whep" :: String)) after)
        Nothing -> v
  where
    -- Find the trailing "/whep" + remainder in the path.
    findWhepSuffix :: String -> Maybe (String, String)
    findWhepSuffix p =
      case breakOn "/whep" p of
        Just (before, rest) -> Just (before, rest)
        Nothing -> Nothing

    -- Returns (prefix before "/whep", "/whep" + rest).
    breakOn :: String -> String -> Maybe (String, String)
    breakOn needle hay
      | needle `isPrefixOf` hay = Just ([], hay)
      | otherwise = case hay of
          [] -> Nothing
          (c : t) -> case breakOn needle t of
            Just (before, rest) -> Just (c : before, rest)
            Nothing -> Nothing
