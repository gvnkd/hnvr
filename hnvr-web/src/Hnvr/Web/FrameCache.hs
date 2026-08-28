{-# LANGUAGE OverloadedStrings #-}

-- | Leader-side cache of remote-node analysis frames.
--
-- The dashboard wall (and the rules drawing canvas) poll
-- @/debug-frame/<cameraId>@, which reads the leader's in-process
-- analyzer. Cameras analyzed on remote worker nodes have no local
-- frames, so their nodes publish a throttled JPEG per frame on
-- @hnvr.frames.<cameraId>@ ('Subjects.framesCamera',
-- 'Hnvr.Node.CaptureSupervisor.publishFrame'). This module subscribes
-- and keeps the latest payload per camera, stamped with the arrival
-- time; 'Hnvr.Web.DebugStream' serves it as a fallback when the local
-- analyzer has nothing.
--
-- The map is camera-count small and each entry is overwritten in
-- place, so no pruning is needed — 'lookupRemoteFrame' age-checks at
-- read time.
module Hnvr.Web.FrameCache
  ( startFrameCache,
    lookupRemoteFrame,
  )
where

import Control.Concurrent.Async (async)
import Control.Monad (forever, void)
import qualified Data.ByteString as BS
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, getCurrentTime)
import qualified Data.UUID as UUID
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Core.Logging (logInfo)
import Hnvr.Nats.Bus (Bus)
import qualified Hnvr.Nats.Bus as Bus
import qualified Hnvr.Nats.Subjects as Subjects
import System.IO.Unsafe (unsafePerformIO)

{-# NOINLINE remoteFrames #-}

-- | Latest (jpeg, arrivalTime) per camera, process-wide — same pattern
-- as 'Hnvr.Web.SupervisorRegistry.supervisorRegistry' (WAI middleware
-- has no app context to thread state through).
remoteFrames :: IORef (M.Map CameraId (BS.ByteString, UTCTime))
remoteFrames = unsafePerformIO (newIORef M.empty)

-- | Subscribe to the frame channel and keep the newest payload per
-- camera. Idempotent to call once per leader process.
startFrameCache :: Bus -> IO ()
startFrameCache bus = do
  sub <- Bus.subscribe bus (Subjects.framesCamera ">")
  void . async . forever $ do
    msg <- Bus.readMessage sub
    case T.stripPrefix (Subjects.framesCamera "") (Bus.msgSubject msg) of
      Just cid
        | Just uuid <- UUID.fromText cid -> do
            now <- getCurrentTime
            atomicModifyIORef' remoteFrames (\m -> (M.insert (CameraId uuid) (Bus.msgPayload msg, now) m, ()))
      _ -> pure ()
  logInfo "FrameCache: subscribed to hnvr.frames.> (remote-node dashboard frames)"

-- | Latest remote frame for a camera, if any. Freshness is judged by
-- the caller (arrival time, not capture time).
lookupRemoteFrame :: CameraId -> IO (Maybe (BS.ByteString, UTCTime))
lookupRemoteFrame camId = M.lookup camId <$> readIORef remoteFrames
