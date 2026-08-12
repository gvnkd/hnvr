{-# LANGUAGE OverloadedStrings #-}

-- | Leader-side SnapshotResponder.
--
-- Subscribes to @hnvr.commands.snapshot.<host>@ and replies to the
-- requester's inbox with the JSON-encoded list of cameras currently
-- assigned to that host. Bridges the bootstrap problem: when a node
-- boots it has no NATS memory of past @hnvr.commands.assign.<slug>@
-- messages (core-NATS is ephemeral; JetStream durability is deferred
-- per pitfall #2 / P0-1). The snapshot reply is the node's only source
-- of truth for its initial worker set.
--
-- The query is small and indexed (@cameras_assigned_idx@ on
-- @assigned_host WHERE enabled@); we re-run it per request rather than
-- maintaining a leader-side cache. At 1 snapshot per node boot (and
-- rare re-resolves) the cost is negligible.
module Hnvr.Web.SnapshotResponder
  ( startSnapshotResponder,
  )
where

import Control.Concurrent.Async (async)
import Control.Exception (SomeException, bracket, catch)
import Control.Monad (forever)
import Data.Aeson (encode)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Database.PostgreSQL.Simple (Only (..))
import qualified Database.PostgreSQL.Simple as PG
import Hnvr.Core.CameraSnapshot
  ( CameraSnapshot (..),
    CameraSnapshotBatch (..),
    transportFromText,
  )
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Core.Logging (logError, logInfo, logWarn)
import Hnvr.Nats.Bus (Bus, Message (..))
import qualified Hnvr.Nats.Bus as Bus
import qualified System.Environment as Env

-- | Spawn the responder in a background 'async'. Subscribes to
-- @hnvr.commands.snapshot.>@ and replies to each message's @replyTo@
-- with a 'CameraSnapshotBatch' JSON payload.
startSnapshotResponder :: Bus -> IO ()
startSnapshotResponder bus = do
  _ <- async loop
  logInfo "SnapshotResponder: subscribed to hnvr.commands.snapshot.>"
  where
    loop =
      forever $ do
        sub <- Bus.subscribe bus "hnvr.commands.snapshot.>"
        msg <- Bus.readMessage sub
        handleRequest bus msg
          `catch` \(e :: SomeException) ->
            logError ("SnapshotResponder: handler failed: " <> T.pack (show e))

-- | Extract the target host from the subject, fetch assigned cameras,
-- encode as 'CameraSnapshotBatch', reply via the message's @replyTo@.
-- Silently drops messages with no @replyTo@ (malformed requester).
handleRequest :: Bus -> Message -> IO ()
handleRequest bus msg =
  case msgReplyTo msg of
    Nothing -> logWarn ("SnapshotResponder: no replyTo on " <> msgSubject msg <> ", dropping")
    Just replyTo -> do
      let host = lastDotToken (msgSubject msg)
      cams <- fetchAssignedCameras host
      let batch = CameraSnapshotBatch {csbCameras = cams}
          payload = BL.toStrict (encode batch)
      Bus.reply bus (Just replyTo) payload
      logInfo ("SnapshotResponder: replied to " <> host <> " with " <> T.pack (show (length cams)) <> " camera(s)")
  where
    lastDotToken s = case T.breakOnEnd "." s of
      ("", _) -> s
      (_, t) -> t

-- | One-shot PG connection: SELECT id, slug, rtsp_url, rtsp_transport,
-- record_audio FROM cameras WHERE assigned_host = ? AND enabled = TRUE.
-- Cameras with an unrecognised transport value are silently skipped
-- (matches 'Hnvr.Web.CommandTypes.projectCamera' semantics — better to
-- under-populate than to spawn a worker that will crash on ffmpeg SETUP).
fetchAssignedCameras :: Text -> IO [CameraSnapshot]
fetchAssignedCameras host = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn -> do
    rows <-
      PG.query
        conn
        "SELECT id, slug, rtsp_url, rtsp_transport, record_audio, rtsp_sub_url, use_substream_for_analysis, substream_width, substream_height, analysis_fps FROM cameras WHERE assigned_host = ? AND enabled = TRUE"
        (Only host)
    pure (foldMap mkSnapshot rows)
  where
    mkSnapshot (cid, slug, url, transportTxt, recordAudio, subUrl, useSub, subW, subH, fps) =
      case transportFromText transportTxt of
        Just tr ->
          [ CameraSnapshot
              { csId = CameraId cid,
                csSlug = slug,
                csRtspUrl = url,
                csTransport = tr,
                csRecordAudio = recordAudio,
                csRtspSubUrl = subUrl,
                csUseSubstream = useSub,
                csSubWidth = fromIntegral <$> subW,
                csSubHeight = fromIntegral <$> subH,
                csAnalysisFps = fromIntegral fps
              }
          ]
        Nothing -> []

-- | Default DB URL matches IHP's. Real deployments set DATABASE_URL.
defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"
