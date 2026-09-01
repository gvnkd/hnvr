{-# LANGUAGE OverloadedStrings #-}

-- | Reverse-proxy sub-path support: split a public base URL into the
-- origin part (scheme\/\/host[:port]) and a normalized path prefix.
--
-- IHP v1.6 has no base-path concept: 'pathTo' emits root-relative
-- paths and redirects go through @APPROOT@ (see hnvr-admin). Running
-- hnvr-admin behind @https://host/admin/@ therefore needs three
-- pieces sharing one parse:
--
--   * the WAI prefix-strip middleware (AdminWeb.BasePath) matches
--     'basePathSegments' against 'pathInfo';
--   * views prepend the prefix to every root-relative URL literal;
--   * @APPROOT@\/@BaseUrl@ are set to the FULL url (path included) so
--     'redirectToPath' emits @https://host/admin/<path>@.
--
-- Pure and WAI-free so it is cabal-testable (pitfall #14).
module Hnvr.Core.BasePath
  ( splitBaseUrl,
    normalizeBasePath,
    basePathSegments,
    stripBasePathPrefix,
  )
where

import Data.List (stripPrefix)
import Data.Text (Text)
import qualified Data.Text as T

-- | Split @https://host:8080/admin/@ into
-- @(\"https://host:8080/admin\", \"/admin\")@ — the first component
-- keeps the path (it is what redirects must emit), the second is the
-- normalized prefix ('normalizeBasePath'). A URL without a path gives
-- @\"\"@ as the prefix. Trailing slashes are dropped from both.
splitBaseUrl :: Text -> (Text, Text)
splitBaseUrl url =
  let afterScheme = case T.breakOn "://" url of
        (_, rest)
          | T.null rest -> url -- no scheme: treat the whole thing as authority+path
          | otherwise -> T.drop 3 rest
      (_, path) = T.breakOn "/" afterScheme
      basePath = normalizeBasePath path
      baseUrl = T.dropWhileEnd (== '/') url
   in (baseUrl, basePath)

-- | Normalize a URL path component into a mount prefix: @\"\"@ and
-- @\"/\"@ mean \"mounted at root\" (@\"\"@); anything else gets exactly
-- one leading @/@ and no trailing @/@. Multi-segment prefixes
-- (@\/nvr\/admin@) are preserved.
normalizeBasePath :: Text -> Text
normalizeBasePath p =
  let stripped = T.dropWhileEnd (== '/') (T.dropWhile (== '/') p)
   in if T.null stripped then "" else "/" <> stripped

-- | The prefix as 'pathInfo' segments (no empties) for list-prefix
-- matching against a WAI request.
basePathSegments :: Text -> [Text]
basePathSegments = filter (not . T.null) . T.splitOn "/"

-- | Strip a normalized prefix from a request path, returning the
-- remaining pathInfo segments. 'Nothing' when the path is not under
-- the prefix (caller 404s). The empty prefix matches everything.
-- @\/admin@ itself maps to the root (@[]@); @\/adminfoo@ does NOT
-- match @\/admin@ (segment-wise, not string-wise).
stripBasePathPrefix :: Text -> [Text] -> Maybe [Text]
stripBasePathPrefix basePath = stripPrefix (basePathSegments basePath)
