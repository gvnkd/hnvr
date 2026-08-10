{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Leader-side HealthCache.
--
-- Subscribes to @hnvr.health.>@ on the leader's NATS bus and maintains
-- an in-memory @IORef (Map HostId Health)@. Two consumers:
--
--   * @/hosts@ dashboard (Phase 2 Slice 6) reads the IORef directly for
--     O(1) rendering.
--   * @AssignmentCoordinator@ (Phase 2 Slice 5) reads the IORef to
--     detect host-down (no entry updated in 15 s).
--
-- Also writes the latest health to the @hosts@ table on every message
-- (debounced write — single UPDATE per heartbeat, ~0.2 QPS at 5 s
-- heartbeat × 2 hosts). The DB row is the source of truth for cross-
-- process restart scenarios; the IORef is the hot read path.
module Hnvr.Web.HealthCache
  ( startHealthCache,
    HealthCache,
    readHealthCache,
    HealthSnapshot (..),
  )
where

import Control.Concurrent.Async (async)
import Control.Exception (SomeException, catch)
import Control.Monad (forever, void)
import Data.Aeson (FromJSON, encode)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.KeyMap as KeyMap
import Data.IORef
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import Data.Time.Clock (getCurrentTime)
import Hnvr.Core.Logging (logError, logInfo)
import Hnvr.Nats.Bus (Bus, Message (..), Subscription)
import qualified Hnvr.Nats.Bus as Bus
import IHP.ModelSupport (ModelContext, sqlExec)

-- | Opaque handle holding the live snapshot.
newtype HealthCache = HealthCache (IORef HealthSnapshot)

-- | Map host → latest health JSON + receive timestamp.
type HealthSnapshot = Map.Map Text Aeson.Value

-- | Read the current snapshot. Cheap — IORef read.
readHealthCache :: HealthCache -> IO HealthSnapshot
readHealthCache (HealthCache ref) = readIORef ref

-- | Spawn the HealthCache in a background async. Returns a handle
-- immediately. The handle is shared via the leader's app context once
-- Slice 6 needs it in controllers.
startHealthCache :: (?modelContext :: ModelContext) => Bus -> IO HealthCache
startHealthCache bus = do
  ref <- newIORef Map.empty
  sub <- Bus.subscribe bus "hnvr.health.>"
  _ <- async (drain sub ref)
  logInfo "HealthCache: subscribed to hnvr.health.>"
  pure (HealthCache ref)

drain :: (?modelContext :: ModelContext) => Subscription -> IORef HealthSnapshot -> IO ()
drain sub ref = forever $ do
  msg <- Bus.readMessage sub
  case Aeson.decodeStrict' (msgPayload msg) :: Maybe Aeson.Value of
    Just v ->
      handleHealth msg v ref `catch` \(e :: SomeException) ->
        logError ("HealthCache: handle failed: " <> T.pack (show e))
    Nothing -> pure ()

-- | Parse host from the subject (@hnvr.health.<host>@), update IORef,
-- write-through to DB.
handleHealth :: (?modelContext :: ModelContext) => Message -> Aeson.Value -> IORef HealthSnapshot -> IO ()
handleHealth msg v ref = do
  let subj = msgSubject msg
      host = T.drop (T.length "hnvr.health.") subj
  now <- getCurrentTime
  -- Augment the payload with leader-receive timestamp for staleness check.
  let v' = case v of
        Aeson.Object o -> Aeson.Object (KeyMap.insert "received_at" (Aeson.String (T.pack (show now))) o)
        _ -> v
  atomicModifyIORef' ref (\m -> (Map.insert host v' m, ()))
  persistHostHealth host v'

-- | UPSERT into hosts table. Uses @sqlExec@ with raw SQL because IHP's
-- @updateRecord@ requires fetching first; this is a fire-and-forget
-- write. The hosts table may not have a row for this host yet (auto-
-- create on first heartbeat).
persistHostHealth :: (?modelContext :: ModelContext) => Text -> Aeson.Value -> IO ()
persistHostHealth host v = do
  -- Encode to Text and let PG cast on the way in (?::jsonb). hasql maps
  -- ByteString to bytea which won't auto-cast to jsonb.
  let jsonText = TL.toStrict (TLE.decodeUtf8 (encode v))
  void $
    sqlExec
      "INSERT INTO hosts (id, display_name, last_health_at, health_json) \
      \ VALUES (?, ?, NOW(), ?::jsonb) \
      \ ON CONFLICT (id) DO UPDATE SET \
      \   last_health_at = NOW(), \
      \   health_json = EXCLUDED.health_json"
      (host, host, jsonText)
