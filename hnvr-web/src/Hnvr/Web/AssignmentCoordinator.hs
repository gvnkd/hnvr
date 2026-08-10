{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Leader-side AssignmentCoordinator.
--
-- Maintains @cameras.assigned_host@ by:
--
--   * Default: keeps the current assignment when the host is healthy
--     (avoids flapping).
--   * On host-down: redistributes that host's cameras to the least-
--     loaded healthy host.
--   * On first boot / new camera: assigns to the least-loaded healthy
--     host.
--
-- @manual_assign=true@ cameras are never auto-reassigned — they're
-- pinned to whatever the admin set in the UI.
--
-- Publishes @hnvr.commands.assign.<cam>@ for every change so each
-- host's @ConfigWatcher@ can start/stop the corresponding worker.
--
-- "Healthy" = a row in the @hosts@ table with @last_health_at@ within
-- the last 15 s (the @HealthCache@ refreshes this on every heartbeat).
module Hnvr.Web.AssignmentCoordinator
  ( startAssignmentCoordinator,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Exception (SomeException, catch)
import Control.Monad (forM_, forever, unless, void, when)
import Data.Aeson (ToJSON (..), Value, object, (.=))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import Generated.Types
import Hnvr.Core.Logging (logError, logInfo)
import Hnvr.Nats.Bus (Bus)
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Nats.Subjects (commandAssign, commandControl)
import IHP.Fetch (fetch)
import IHP.HaskellSupport (get, (|>))
import IHP.ModelSupport (ModelContext, sqlExec, sqlQuery)
import IHP.QueryBuilder (filterWhere, orderByAsc, query)

-- | Host-down timeout. Matches the design's 15 s budget (Phase 2 demo
-- requirement: cameras reassigned within 15 s of host-down).
staleTimeoutSeconds :: NominalDiffTime
staleTimeoutSeconds = 15

-- | Poll interval. 5 s = good balance between reactivity and DB load
-- (one indexed query per tick).
pollIntervalMicros :: Int
pollIntervalMicros = 5_000_000

-- | Spawn the coordinator in a background async.
startAssignmentCoordinator :: (?modelContext :: ModelContext) => Bus -> IO ()
startAssignmentCoordinator bus = do
  _ <- async loop
  logInfo "AssignmentCoordinator: started (5s poll, 15s host-down timeout)"
  where
    loop =
      forever $ do
        reconcile bus
          `catch` \(e :: SomeException) ->
            logError ("AssignmentCoordinator: reconcile failed: " <> T.pack (show e))
        threadDelay pollIntervalMicros

-- | One reconciliation pass.
reconcile :: (?modelContext :: ModelContext) => Bus -> IO ()
reconcile bus = do
  now <- getCurrentTime
  hosts <- healthyHosts now
  if null hosts
    then pure () -- no healthy hosts; nothing to do
    else do
      cameras <-
        query @Camera
          |> filterWhere (#enabled, True)
          |> orderByAsc #slug
          |> fetch
      let reassigned = mapMaybe (pickTarget hosts) cameras
      mapM_ (applyAssignment bus) reassigned
      unless (null reassigned) $
        logInfo
          ( "AssignmentCoordinator: reassigned "
              <> T.pack (show (length reassigned))
              <> " camera(s)"
          )

-- | Decide whether a camera needs reassignment, and to which host.
-- Returns (camera, new host, slug) when a change is needed; Nothing
-- otherwise.
pickTarget :: Map.Map Text UTCTime -> Camera -> Maybe (Camera, Text, Text)
pickTarget healthy cam
  | cam.manualAssign = Nothing
  | otherwise =
      let current = cam.assignedHost
          currentHealthy = maybe False (`Map.member` healthy) current
       in if currentHealthy
            then Nothing
            else Just (cam, leastLoaded healthy, cam.slug)

-- | Pick the healthy host with the lex-smallest id. Slice 5b will
-- query per-host load; v1 with 2 hosts doesn't need real load
-- balancing (the "keep if healthy" rule prevents flapping).
leastLoaded :: Map.Map Text a -> Text
leastLoaded healthy =
  case Map.keys healthy of
    (h : _) -> h
    [] -> "hnvr-2"

-- | Write the new assignment to DB and publish the NATS command.
--
-- Per @03-capture-and-storage.md@ §"Reassignment sequence" step 6: when
-- a camera is moving between hosts, the old host receives a
-- @hnvr.commands.control.<old_host>.<cam>.stop@ directive so it can
-- drain gracefully. Cameras without a prior host (first assignment)
-- emit no stop. The new host learns of the assignment via the regular
-- @hnvr.commands.assign.<slug>@ message.
applyAssignment :: (?modelContext :: ModelContext) => Bus -> (Camera, Text, Text) -> IO ()
applyAssignment bus (cam, newHost, slug) = do
  void $
    sqlExec
      "UPDATE cameras SET assigned_host = ?, updated_at = NOW() WHERE id = ?"
      (newHost, cam |> get #id)
  -- Graceful drain directive to the old host, if any.
  forM_ cam.assignedHost $ \oldHost ->
    when (oldHost /= newHost) $
      Bus.publishJson bus (commandControl oldHost slug "stop") (ControlMsg slug "stop")
  Bus.publishJson bus (commandAssign slug) (AssignMsg slug newHost)

-- | Wire payload for @hnvr.commands.assign.<slug>@.
data AssignMsg = AssignMsg
  { amSlug :: !Text,
    amHost :: !Text
  }

instance ToJSON AssignMsg where
  toJSON m =
    object
      [ "slug" .= m.amSlug,
        "host" .= m.amHost
      ]

-- | Wire payload for @hnvr.commands.control.<host>.<cam>.<action>@.
-- Echoes the slug + action so the subscriber can correlate against the
-- subject tokens (which the nats-queue lib doesn't expose cleanly).
data ControlMsg = ControlMsg
  { cmSlug :: !Text,
    cmAction :: !Text
  }

instance ToJSON ControlMsg where
  toJSON m =
    object
      [ "slug" .= m.cmSlug,
        "action" .= m.cmAction
      ]

-- | Query the @hosts@ table for rows with @last_health_at@ within the
-- stale-timeout window. Returns Map hostId lastHealthAt.
--
-- Slice 5 MVP: uses raw SQL via 'sqlQuery'-equivalent. We re-use
-- 'sqlExec'-style snippet params; for SELECT we use IHP's @sqlQuery@.
healthyHosts :: (?modelContext :: ModelContext) => UTCTime -> IO (Map.Map Text UTCTime)
healthyHosts now = do
  rows <-
    sqlQuery
      "SELECT id, last_health_at FROM hosts \
      \ WHERE last_health_at IS NOT NULL \
      \   AND last_health_at >= NOW() - INTERVAL '15 seconds'"
      ()
  pure $
    Map.fromList
      [ (host, ts)
      | (host, ts) <- rows,
        diffUTCTime now ts < staleTimeoutSeconds
      ]
