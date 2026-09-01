{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Reverse-proxy sub-path glue shared by hnvr-leader and hnvr-admin
-- (HNVR_BASE_URL / HNVR_ADMIN_BASE_URL with a path component, e.g.
-- @https://host/hnvr@). The pure parsing lives in
-- "Hnvr.Core.BasePath"; this module is the WAI half:
--
--   * 'stripBasePathMiddleware' — removes the mount prefix from
--     'pathInfo'\/'rawPathInfo' and stashes it in the request vault;
--   * 'mountMiddleware' — the same, plus serves @\<prefix\>/static/*@
--     itself. Needed on the leader: 'IHP.Server.run' applies its
--     static shortcut OUTSIDE the middleware stack, so a stripped
--     @/static/*@ request would reach the router's fallback static app
--     with the @static@ segment still in 'pathInfo' and miss on disk;
--   * 'urlFor' — prepends the request's prefix to a root-relative
--     path. Every root-relative URL literal in views MUST go through
--     it (identity at root mount, so dev behaviour is unchanged);
--   * redirects need no code here: Config sets @APPROOT@\/@BaseUrl@
--     to the full public URL and IHP's 'redirectToPath' prepends
--     approot.
module Hnvr.Web.BasePath
  ( stripBasePathMiddleware,
    mountMiddleware,
    urlFor,
    requestBasePath,
  )
where

import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vault.Lazy as Vault
import Hnvr.Core.BasePath (stripBasePathPrefix)
import IHP.Prelude
import qualified Network.HTTP.Types as Http
import qualified Network.Wai as Wai
import System.IO.Unsafe (unsafePerformIO)

-- | Per-request vault slot for the mount prefix. Module-level key —
-- the standard wai vault pattern (unsafePerformIO + NOINLINE).
vaultKey :: Vault.Key Text
vaultKey = unsafePerformIO Vault.newKey
{-# NOINLINE vaultKey #-}

-- | Identity for the empty prefix; otherwise strips the prefix
-- segment-wise and 404s anything outside it. Must run BEFORE anything
-- that reads 'rawPathInfo' (static shortcut, auth chain, router).
stripBasePathMiddleware :: Text -> Wai.Middleware
stripBasePathMiddleware basePath app req respond
  | T.null basePath = app req respond
  | otherwise = case stripPrefixRequest basePath req of
      Nothing -> respond notFound
      Just req' -> app req' respond

-- | 'stripBasePathMiddleware' + serving of @\<prefix\>/static/*@ from
-- the given static app (plain wai-app-static over APP_STATIC; the
-- leader's pages load no IHP-framework assets — the layout doesn't
-- load ihp.js). Use this on apps booted via 'IHP.Server.run'; apps
-- with a custom run (hnvr-admin) can place 'stripBasePathMiddleware'
-- outside their own static shortcut instead.
mountMiddleware :: Text -> Wai.Application -> Wai.Middleware
mountMiddleware basePath staticApp app req respond
  | T.null basePath = app req respond
  | otherwise = case stripPrefixRequest basePath req of
      Nothing -> respond notFound
      Just req' -> case Wai.pathInfo req' of
        ("static" : file) ->
          staticApp
            req'
              { Wai.pathInfo = file,
                Wai.rawPathInfo = cs (dropText "/static" (Wai.rawPathInfo req'))
              }
            respond
        _ -> app req' respond

stripPrefixRequest :: Text -> Wai.Request -> Maybe Wai.Request
stripPrefixRequest basePath req =
  case stripBasePathPrefix basePath (Wai.pathInfo req) of
    Nothing -> Nothing
    Just rest ->
      let raw = dropText basePath (Wai.rawPathInfo req)
          raw' = if T.null raw then "/" else raw
       in Just
            req
              { Wai.pathInfo = rest,
                Wai.rawPathInfo = cs raw',
                Wai.vault = Vault.insert vaultKey basePath (Wai.vault req)
              }

-- | Drop a textual prefix from a raw path. Our prefixes are ASCII and
-- never percent-encoded, so a plain 'T.stripPrefix' is exact.
dropText :: Text -> ByteString -> Text
dropText prefix raw = fromMaybe "" (T.stripPrefix prefix (cs raw))

notFound :: Wai.Response
notFound = Wai.responseLBS Http.status404 [("Content-Type", "text/plain")] "not found"

-- | The prefix this request arrived under (@\"\"@ at root mount).
requestBasePath :: (?request :: Wai.Request) => Text
requestBasePath =
  let req = ?request
   in fromMaybe "" (Vault.lookup vaultKey req.vault)

-- | Prefix a root-relative path for the current request. Hardcoded
-- @href=\"\/Timeline\"@ bypasses the mount and 404s behind the proxy.
urlFor :: (?request :: Wai.Request) => Text -> Text
urlFor path = requestBasePath <> path
