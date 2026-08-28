{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | /debug-frame/<camera-uuid> — one-shot PNG of the latest analysis
-- frame (dashboard live wall + the Phase 4 rules UI drawing canvas).
-- Anonymous-readable by design (the dashboard is anonymous-readable).
--
-- WAI middleware (like 'Hnvr.Web.WhepProxy') because IHP controllers
-- don't own long-lived streaming responses. Reads the camera's
-- @latestAnalysis@ TVar from the process-wide
-- 'Hnvr.Web.SupervisorRegistry'.
--
-- The live multipart overlay stream moved to the session-gated
-- @StreamDebugCameraAction@ controller ('debugStreamResponse' is the
-- shared renderer).
module Hnvr.Web.DebugStream
  ( debugStreamMiddleware,
    debugStreamResponse,
  )
where

import Control.Concurrent.STM
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Data.IORef (readIORef)
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (NominalDiffTime, diffUTCTime, getCurrentTime)
import qualified Data.UUID as UUID
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Cv.DebugRender (renderDebugPng)
import Hnvr.Cv.Tracker.Sort (Track)
import Hnvr.Node.CaptureSupervisor (latestAnalysis)
import Hnvr.Web.FrameCache (lookupRemoteFrame)
import Hnvr.Web.SupervisorRegistry (supervisorRegistry)
import Network.HTTP.Types (status200, status404, status503)
import Network.Wai

debugStreamMiddleware :: Middleware
debugStreamMiddleware app req respond =
  case pathInfo req of
    ["debug-frame", uuidTxt] -> handleStill uuidTxt
    _ -> app req respond
  where
    -- One-shot PNG of the latest frame (no track overlay — the rules
    -- canvas draws its own geometry on top). 404 until the first
    -- frame lands. 503 when the cached frame is stale: the analysis
    -- TVar is never cleared on ffmpeg death, so without the age check
    -- a dead camera kept serving its last frame with a 200 and the
    -- dashboard wall showed it as live forever.
    handleStill uuidTxt =
      case UUID.fromText uuidTxt of
        Nothing -> respond (text status404 "malformed camera id")
        Just uuid -> do
          now <- getCurrentTime
          mLocal <-
            readIORef supervisorRegistry >>= \case
              Nothing -> pure Nothing
              Just sup -> latestAnalysis sup (CameraId uuid)
          let localFresh = case mLocal of
                Just (frame, _tracks)
                  | diffUTCTime now (frameTimestamp frame) <= maxFrameAgeSeconds ->
                      Just (responseLBS status200 [("Content-Type", "image/png"), ("Cache-Control", "no-cache")] (renderDebugPng frame []))
                _ -> Nothing
          case localFresh of
            Just resp -> respond resp
            Nothing -> do
              -- Remote-node camera: the leader has no local analyzer
              -- for it; serve the newest NATS frame-channel JPEG
              -- ('Hnvr.Web.FrameCache') when it arrived recently.
              mRemote <- lookupRemoteFrame (CameraId uuid)
              case mRemote of
                Just (jpeg, arrived)
                  | diffUTCTime now arrived <= maxFrameAgeSeconds ->
                      respond (responseLBS status200 [("Content-Type", "image/jpeg"), ("Cache-Control", "no-cache")] (BL.fromStrict jpeg))
                _ -> respond $ case mLocal of
                  -- 404 until the first frame lands; 503 when the cached
                  -- frame is stale: the analysis TVar is never cleared on
                  -- ffmpeg death, so without the age check a dead camera
                  -- kept serving its last frame with a 200 and the
                  -- dashboard wall showed it as live forever.
                  Nothing -> text status404 "no frame yet"
                  Just _ -> text status503 "stale frame — camera unavailable"

    -- Frames arrive at analysis_fps (>= 1/s on any sane config); 5 s
    -- without a fresh frame means the source is dead.
    maxFrameAgeSeconds :: NominalDiffTime
    maxFrameAgeSeconds = 5

    text st msg =
      responseLBS st [("Content-Type", "text/plain")] (BL.fromStrict (TE.encodeUtf8 msg))

-- | Multipart @x-mixed-replace@ response emitting one PNG part per
-- analyzed frame; blocks on the TVar via STM between frames. Used by
-- the session-gated @StreamDebugCameraAction@.
debugStreamResponse :: TVar (Maybe (Frame, [Track])) -> Response
debugStreamResponse tvar =
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
