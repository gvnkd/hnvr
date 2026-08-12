{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | /debug-stream/<camera-uuid> — multipart stream of the analysis
-- overlay (Phase 3 debug view).
--
-- WAI middleware (like 'Hnvr.Web.WhepProxy') because IHP controllers
-- don't own long-lived streaming responses. Reads the camera's
-- @latestAnalysis@ TVar from the process-wide
-- 'Hnvr.Web.SupervisorRegistry', blocks on changes via STM, and emits
-- one PNG part per analyzed frame.
--
-- Dev-only: unauthenticated (same posture as /whep). Phase 6 gates it
-- behind the session cookie.
module Hnvr.Web.DebugStream
  ( debugStreamMiddleware,
  )
where

import Control.Concurrent.STM
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Data.IORef (readIORef)
import qualified Data.Text.Encoding as TE
import qualified Data.UUID as UUID
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Cv.DebugRender (renderDebugPng)
import Hnvr.Cv.Tracker.Sort (Track)
import Hnvr.Node.CaptureSupervisor (analysisTVar)
import Hnvr.Web.SupervisorRegistry (supervisorRegistry)
import Network.HTTP.Types (status200, status404, status503)
import Network.Wai

debugStreamMiddleware :: Middleware
debugStreamMiddleware app req respond =
  case pathInfo req of
    ["debug-stream", uuidTxt] -> handle uuidTxt
    _ -> app req respond
  where
    handle uuidTxt =
      case UUID.fromText uuidTxt of
        Nothing -> respond (text status404 "malformed camera id")
        Just uuid -> do
          mSup <- readIORef supervisorRegistry
          case mSup of
            Nothing -> respond (text status503 "no capture supervisor on this host")
            Just sup -> do
              mTVar <- analysisTVar sup (CameraId uuid)
              case mTVar of
                Nothing -> respond (text status404 "no analysis running for this camera on this host")
                Just tvar -> respond (stream tvar)

    text st msg =
      responseLBS st [("Content-Type", "text/plain")] (BL.fromStrict (TE.encodeUtf8 msg))

    stream tvar =
      responseStream
        status200
        [ ("Content-Type", "multipart/x-mixed-replace; boundary=hnvrframe"),
          ("Cache-Control", "no-cache")
        ]
        $ \write flush -> loop write flush Nothing
      where
        loop write flush lastTs = do
          (frame, tracks) <- atomically $ do
            v <- readTVar tvar
            case v of
              Just (f, ts)
                | Just (frameTimestamp f) /= lastTs -> pure (f, ts :: [Track])
              _ -> retry
          write (chunk frame tracks) >> flush
          loop write flush (Just (frameTimestamp frame))

    chunk frame tracks =
      let png = renderDebugPng frame tracks
       in mconcat
            [ BB.byteString "--hnvrframe\r\nContent-Type: image/png\r\nContent-Length: ",
              BB.intDec (fromIntegral (BL.length png)),
              BB.byteString "\r\n\r\n",
              BB.lazyByteString png,
              BB.byteString "\r\n"
            ]
