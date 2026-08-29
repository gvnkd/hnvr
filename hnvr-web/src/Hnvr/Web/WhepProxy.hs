{-# LANGUAGE OverloadedStrings #-}

-- | WAI middleware that reverse-proxies @/whep/<slug>@ (and the per-session
-- sub-paths under it) to MediaMTX's WHEP endpoint at
-- @http://127.0.0.1:8889/<slug>/whep@.
--
-- WHEP is a 3-method flow:
--   * POST @/whep/<slug>@ with SDP offer → 201 with SDP answer + Location
--   * PATCH @/whep/<slug>/session/<id>@ with ICE restart SDP
--   * DELETE @/whep/<slug>/session/<id>@ to tear down
--
-- The Location header returned by MediaMTX points back at its own
-- @/<slug>/whep/session/<id>@; we rewrite the prefix so the browser's
-- subsequent PATCH/DELETE land on our proxy path instead.
--
-- Why a middleware (not an IHP controller): WHEP needs raw body access
-- and arbitrary HTTP methods, which IHP's controller dispatch doesn't
-- help with. Doing the proxy at the WAI layer keeps IHP's request flow
-- out of the hot path and matches the @/healthz@ short-circuit pattern
-- in @Hnvr.Web.Config@.
module Hnvr.Web.WhepProxy
  ( whepMiddleware,
    proxyOne,
    defaultMediaMtxWebrtc,
  )
where

import Control.Exception (SomeException, catch)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BSL
import qualified Data.ByteString.Lazy.Char8 as BSLC
import Data.Maybe (fromMaybe)
import Hnvr.Core.Whep (translateBack, translatePath)
import qualified Network.HTTP.Client as HC
import Network.HTTP.Types (status500)
import qualified Network.HTTP.Types as HTTP
import qualified Network.Wai as Wai
import qualified System.Environment as Env

-- | Default MediaMTX WebRTC port (matches the NixOS module's
-- @webrtcPort@ option). Override via @HNVR_MEDIAMTX_WEBRTC@.
defaultMediaMtxWebrtc :: String
defaultMediaMtxWebrtc = "http://127.0.0.1:8889"

-- | Top-level middleware. Passes through any path that doesn't start
-- with @/whep/@. The 'HC.Manager' is created once per request; cheap
-- enough for v1 (http-client reuses connections internally per manager
-- but we accept the per-request overhead to keep the API simple —
-- Slice 6+ can switch to a shared manager in a @TVar@ if it shows up
-- in profiling).
whepMiddleware :: Wai.Middleware
whepMiddleware inner request respond
  | BSC.isPrefixOf "/whep/" (Wai.rawPathInfo request) = do
      mgr <- HC.newManager HC.defaultManagerSettings
      base <- fromMaybe defaultMediaMtxWebrtc <$> Env.lookupEnv "HNVR_MEDIAMTX_WEBRTC"
      proxyOne mgr base request >>= respond
  | otherwise = inner request respond

-- | Issue a single upstream HTTP request and translate the response
-- back to a WAI response. The Location header (if any) gets its prefix
-- rewritten so the browser's subsequent requests land back on us.
--
-- Path translation: @/whep/<slug>[@/session/<id>]@ → @/<slug>/whep[@/session/<id>]@
-- because MediaMTX expects the path-name first, then the @whep@
-- sub-resource.
proxyOne :: HC.Manager -> String -> Wai.Request -> IO Wai.Response
proxyOne mgr base request = do
  body <- Wai.strictRequestBody request
  let upstreamPath = translatePath (Wai.rawPathInfo request)
      method = Wai.requestMethod request
      upBody = BSL.toStrict body
  initReq <- HC.parseRequest (base <> BSC.unpack upstreamPath)
  let upReq =
        initReq
          { HC.method = method,
            HC.requestBody = HC.RequestBodyBS upBody,
            HC.requestHeaders = [("Content-Type", "application/sdp")]
          }
  resp <- HC.httpLbs upReq mgr
  let status = HC.responseStatus resp
      hdrs = map rewriteLocation (HC.responseHeaders resp)
      rspBody = HC.responseBody resp
  pure (Wai.responseLBS status hdrs rspBody)
    `catch` \(e :: SomeException) ->
      pure (Wai.responseLBS status500 [] ("WHEP proxy error: " <> BSLC.pack (show e)))

-- | Rewrite MediaMTX's @/<slug>/whep/session/<id>@ Location header back
-- to our public @/whep/<slug>/session/<id>@ form so the browser's next
-- PATCH/DELETE returns to us. Only rewrites Location / Content-Location.
rewriteLocation :: (HTTP.HeaderName, BS.ByteString) -> (HTTP.HeaderName, BS.ByteString)
rewriteLocation (name, val)
  | name == "Location" || name == "Content-Location" = (name, translateBack val)
  | otherwise = (name, val)
