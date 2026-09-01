{-# LANGUAGE OverloadedStrings #-}

-- | Per-app session cookie isolation behind a shared virtual host.
--
-- IHP hardcodes the session cookie name: @initSessionMiddleware@ is
-- @withSession store \"SESSION\" sessionCookie sessionVaultKey@
-- (IHP/Server.hs) — the @setCookieName@ in the 'SessionCookie' option
-- is silently ignored, so hnvr-leader and hnvr-admin BOTH read and
-- write @SESSION; Path=\/@. On one vhost (leader at @/@, admin at a
-- sub-path) the browser sends the same cookie to both apps and the
-- sessions leak into each other.
--
-- IHP is a pinned nix dependency, so the fix is a translation layer
-- at the edge of each app ('Hnvr.Web.SessionCookie' is the WAI half):
--
--   * inbound — the app's OWN cookie (@hnvr@ \/ @hnvr_admin@) is
--     renamed to @SESSION@ for IHP, and any foreign @SESSION@ (set by
--     the sibling app on the same vhost) is DROPPED;
--   * outbound — @Set-Cookie: SESSION=…@ is renamed back to the app's
--     own name.
--
-- Pure and WAI-free so it is cabal-testable (pitfall #14).
module Hnvr.Core.SessionCookie
  ( ihpSessionCookieName,
    rewriteRequestCookie,
    rewriteSetCookie,
  )
where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC

-- | The cookie name IHP's session middleware actually uses, regardless
-- of the 'SessionCookie' option.
ihpSessionCookieName :: BS.ByteString
ihpSessionCookieName = "SESSION"

-- | Rewrite an inbound Cookie header value: present the app's own
-- cookie (@appName@) to IHP as @SESSION@, drop any foreign @SESSION@
-- and the original @appName@ entry, keep everything else. Cookies are
-- @name=value@ pairs joined by @\"; \"@; values are opaque
-- (clientsession base64+sig, may contain @=@ padding — split on the
-- FIRST @=@ only).
rewriteRequestCookie ::
  -- | appName (e.g. @hnvr@ \/ @hnvr_admin@)
  BS.ByteString ->
  -- | Cookie header value
  BS.ByteString ->
  BS.ByteString
rewriteRequestCookie appName headerValue =
  BSC.intercalate "; " (map render (rest ++ own))
  where
    cookies = filter (not . BS.null . fst) (map parsePair (BSC.split ';' headerValue))
    own = case lookup appName cookies of
      Just v -> [(ihpSessionCookieName, v)]
      Nothing -> []
    rest = filter (\(n, _) -> n /= appName && n /= ihpSessionCookieName) cookies
    render (n, v) = n <> "=" <> v
    parsePair raw =
      let (n, v) = BSC.break (== '=') (BSC.dropWhile (== ' ') raw)
       in (n, if BS.null v then v else BS.tail v)

-- | Rewrite an outbound Set-Cookie header value: @SESSION=…@ becomes
-- @appName=…@ (flags untouched). 'Nothing' when the header is not the
-- session cookie.
rewriteSetCookie ::
  -- | appName
  BS.ByteString ->
  -- | Set-Cookie header value
  BS.ByteString ->
  Maybe BS.ByteString
rewriteSetCookie appName value =
  case BSC.stripPrefix (ihpSessionCookieName <> "=") value of
    Just rest -> Just (appName <> "=" <> rest)
    Nothing -> Nothing
