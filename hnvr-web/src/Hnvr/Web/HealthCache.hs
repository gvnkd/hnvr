{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Leader-side health consumer.
--
-- Subscribes to @hnvr.health.>@ on the leader's NATS bus and writes the
-- latest health to the @hosts@ table on every message (single UPSERT
-- per heartbeat, ~0.2 QPS at 5 s heartbeat × 2 hosts). The DB row is
-- the source of truth for the /Hosts page, the dashboard host panel,
-- per-camera status resolution ('Hnvr.Web.CameraStatus') and the
-- AssignmentCoordinator's host-down detection.
--
-- The UPSERT also stamps @is_leader@: this consumer only runs on the
-- leader, so the reporting host is the leader iff it equals our own
-- @HNVR_HOST@. (Before Aug 2026 nothing ever wrote is_leader and every
-- host rendered as WORKER.)
module Hnvr.Web.HealthCache
  ( startHealthCache,
  )
where

import Control.Concurrent.Async (async)
import Control.Exception (SomeException, catch)
import Control.Monad (forever, void)
import Data.Aeson (FromJSON, encode)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Data.Time.Clock (getCurrentTime)
import Hnvr.Core.Logging (logError, logInfo)
import Hnvr.Nats.Bus (Bus, Message (..), Subscription)
import qualified Hnvr.Nats.Bus as Bus
import IHP.ModelSupport (ModelContext, sqlExec)

-- | Spawn the health consumer in a background async. @leaderHost@ is
-- this process's own @HNVR_HOST@ — used to stamp @is_leader@.
startHealthCache :: (?modelContext :: ModelContext) => Bus -> Text -> IO ()
startHealthCache bus leaderHost = do
  sub <- Bus.subscribe bus "hnvr.health.>"
  _ <- async (drain sub)
  logInfo "HealthCache: subscribed to hnvr.health.>"
  where
    drain sub = forever $ do
      msg <- Bus.readMessage sub
      case Aeson.decodeStrict' (msgPayload msg) :: Maybe Aeson.Value of
        Just v ->
          handleHealth msg v `catch` \(e :: SomeException) ->
            logError ("HealthCache: handle failed: " <> T.pack (show e))
        Nothing -> pure ()
    handleHealth msg v = do
      let subj = msgSubject msg
          host = T.drop (T.length "hnvr.health.") subj
      now <- getCurrentTime
      -- Augment the payload with leader-receive timestamp for staleness
      -- checks by JSON consumers.
      let v' = case v of
            Aeson.Object o -> Aeson.Object (KeyMap.insert "received_at" (Aeson.String (T.pack (show now))) o)
            _ -> v
      persistHostHealth leaderHost host v'

-- | UPSERT into hosts table. Uses @sqlExec@ with raw SQL because IHP's
-- @updateRecord@ requires fetching first; this is a fire-and-forget
-- write. The hosts table may not have a row for this host yet (auto-
-- create on first heartbeat). @gpu_model@ and @exec_providers@ are
-- lifted out of the payload into their own columns (dashboard + /Hosts
-- render them directly). Both are COALESCE-guarded: a reporter running
-- an older build (no such payload keys) must not wipe values a newer
-- reporter wrote.
persistHostHealth :: (?modelContext :: ModelContext) => Text -> Text -> Aeson.Value -> IO ()
persistHostHealth leaderHost host v = do
  -- Encode to Text and let PG cast on the way in (?::jsonb). hasql maps
  -- ByteString to bytea which won't auto-cast to jsonb.
  let jsonText = TL.toStrict (TLE.decodeUtf8 (encode v))
      gpuModel = case v of
        Aeson.Object o -> case KeyMap.lookup "gpu_model" o of
          Just (Aeson.String t) -> Just t
          _ -> Nothing
        _ -> Nothing
      execProviders :: Maybe [Text]
      execProviders = case v of
        Aeson.Object o -> case KeyMap.lookup "exec_providers" o of
          Just pv -> case Aeson.fromJSON pv of
            Aeson.Success eps -> Just eps
            Aeson.Error _ -> Nothing
          Nothing -> Nothing
        _ -> Nothing
      isLeader = host == leaderHost
  void $
    sqlExec
      "INSERT INTO hosts (id, last_health_at, health_json, gpu_model, exec_providers, is_leader) \
      \ VALUES (?, NOW(), ?::jsonb, ?, COALESCE(?, ARRAY['cpu']::text[]), ?) \
      \ ON CONFLICT (id) DO UPDATE SET \
      \   last_health_at = NOW(), \
      \   health_json = EXCLUDED.health_json, \
      \   gpu_model = COALESCE(?, hosts.gpu_model), \
      \   exec_providers = COALESCE(?, hosts.exec_providers), \
      \   is_leader = EXCLUDED.is_leader"
      (host, jsonText, gpuModel, execProviders, isLeader, gpuModel, execProviders)
