{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | WAI half of per-app session cookie isolation — see
-- "Hnvr.Core.SessionCookie" for why IHP's hardcoded @SESSION@ cookie
-- makes this necessary. Wraps the app OUTSIDE IHP's session
-- middleware (via the CustomMiddleware option, the outermost slot):
-- inbound it renames the app's own cookie to @SESSION@ (dropping any
-- foreign @SESSION@ from a sibling app on the same vhost), outbound
-- it renames @Set-Cookie: SESSION@ back. One deployment consequence:
-- renaming the leader's cookie (@hnvr@) invalidates existing leader
-- sessions once.
module Hnvr.Web.SessionCookie
  ( sessionCookieMiddleware,
  )
where

import qualified Data.ByteString as BS
import Hnvr.Core.SessionCookie (rewriteRequestCookie, rewriteSetCookie)
import IHP.Prelude
import qualified Network.Wai as Wai

sessionCookieMiddleware ::
  -- | this app's cookie name (@hnvr@ \/ @hnvr_admin@)
  BS.ByteString ->
  Wai.Middleware
sessionCookieMiddleware appCookieName app req respond =
  app
    req {Wai.requestHeaders = map rewriteIn (Wai.requestHeaders req)}
    (respond . Wai.mapResponseHeaders (map rewriteOut))
  where
    rewriteIn (name, value)
      | name == "Cookie" = (name, rewriteRequestCookie appCookieName value)
      | otherwise = (name, value)
    rewriteOut (name, value)
      | name == "Set-Cookie" =
          case rewriteSetCookie appCookieName value of
            Just renamed -> (name, renamed)
            Nothing -> (name, value)
      | otherwise = (name, value)
