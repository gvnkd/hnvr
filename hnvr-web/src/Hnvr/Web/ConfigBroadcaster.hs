{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Leader-side ConfigBroadcaster.
--
-- Mirrors the MediaMTXConfigSyncer pattern: LISTEN on the Postgres
-- @cameras_events@ channel (installed idempotently by MediaMTXConfigSyncer)
-- and republish each camera row as JSON on @hnvr.config.cameras.<slug>@.
-- Per @design_docs/01-architecture.md@ and @05-web-and-live-view.md@ the
-- node-side ConfigWatcher subscribes this subject and maintains an
-- @IORef (Map CameraId Camera)@ for the analyzer pipeline (Phase 3+).
--
-- Why both LISTEN/NOTIFY and a NATS echo: the leader is the only writer
-- to @cameras@, so the broadcast is naturally fan-out from a single
-- producer. Subscribing NATS keeps the protocol uniform across hosts
-- (the node doesn't need PG credentials just to learn about config).
--
-- Today (Phase 2) the node-side ConfigWatcher only logs broadcasts;
-- Phase 3 wires it into the CaptureSupervisor's config IORef.
module Hnvr.Web.ConfigBroadcaster
  ( startConfigBroadcaster,
  )
where

import Control.Concurrent.Async (async)
import Control.Exception (SomeException, catch)
import Control.Monad (forever)
import Data.Aeson (Value (..))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Database.PostgreSQL.Simple (Connection, Only (..))
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.Notification as PG
import Hnvr.Core.Logging (logError, logInfo, logWarn)
import Hnvr.Nats.Bus (Bus)
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Nats.Subjects (configCameras)
import IHP.ModelSupport (ModelContext)
import qualified System.Environment as Env

-- | Spawn the broadcaster in a background async. Idempotent.
-- Reuses the @cameras_events@ trigger installed by
-- 'Hnvr.Web.MediaMTXConfigSyncer.ensureTrigger' — no second trigger is
-- created here.
startConfigBroadcaster :: (?modelContext :: ModelContext) => Bus -> IO ()
startConfigBroadcaster bus = do
  _ <- async listenLoop
  logInfo "ConfigBroadcaster: started, listening on cameras_events"
  where
    listenLoop = do
      dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
      listenWith dbUrl (handleNotif bus)
        `catch` \(e :: SomeException) ->
          logError ("ConfigBroadcaster: LISTEN loop died: " <> T.pack (show e))

-- | Default DB URL matches IHP's. Real deployments set DATABASE_URL.
defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"

-- | Connect, LISTEN, loop. Reconnect logic deferred (matches the
-- MediaMTXConfigSyncer Slice 2b TODO).
listenWith :: BSC.ByteString -> (PG.Notification -> IO ()) -> IO ()
listenWith dbUrl onNotif = do
  conn <- PG.connectPostgreSQL dbUrl
  _ <- PG.execute_ conn "LISTEN cameras_events"
  logInfo "ConfigBroadcaster: LISTEN cameras_events"
  forever $ do
    n <- PG.getNotification conn
    onNotif n

-- | Decode the trigger payload (@{"op":"INSERT|UPDATE|DELETE","slug":"<s>"}@)
-- and broadcast the camera row JSON on @hnvr.config.cameras.<slug>@.
-- DELETE has no row to publish — emit an explicit null so subscribers
-- can drop the entry from their cache (Phase 3 IORef).
handleNotif :: Bus -> PG.Notification -> IO ()
handleNotif bus notif =
  case Aeson.decode (BL.fromStrict (PG.notificationData notif)) of
    Just (payload :: NotifPayload) -> do
      let slug = payload.npSlug
      case payload.npOp of
        "DELETE" ->
          Bus.publishJson bus (configCameras slug) (String "null")
        _ -> do
          -- Best-effort fetch of the row JSON. Failures logged; we don't
          -- crash the loop because the next change will retry.
          mRow <- fetchCameraJson slug
          case mRow of
            Just rowJson ->
              Bus.publishJson bus (configCameras slug) rowJson
            Nothing ->
              logWarn ("ConfigBroadcaster: could not fetch row JSON for slug " <> slug)
    Nothing ->
      logWarn "ConfigBroadcaster: failed to decode cameras_events payload"

-- | Trigger payload shape emitted by @hnvr_notify_cameras_events()@.
data NotifPayload = NotifPayload
  { npOp :: !Text,
    npSlug :: !Text
  }

instance Aeson.FromJSON NotifPayload where
  parseJSON = Aeson.withObject "NotifPayload" $ \o ->
    NotifPayload
      <$> o Aeson..: "op"
      <*> o Aeson..: "slug"

-- | Open a one-shot connection and fetch the row JSON for a slug.
-- We re-open rather than reuse the LISTEN connection because the LISTEN
-- connection must stay in idle state to receive NOTIFYs. The query uses
-- @row_to_json@ so the wire payload is exactly the camera record.
--
-- TODO Phase 3: when the node-side ConfigWatcher actually populates an
-- IORef, we should pin the JSON schema (camelCase keys, explicit
-- codec). For now the row_to_json shape is informational.
fetchCameraJson :: Text -> IO (Maybe Value)
fetchCameraJson slug = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  conn <- PG.connectPostgreSQL dbUrl
  rows <- PG.query @_ @(Only Value) conn "SELECT row_to_json(t) FROM (SELECT * FROM cameras WHERE slug = ?) t" (Only slug)
  pure $ case rows of
    [Only v] -> Just v
    _ -> Nothing
