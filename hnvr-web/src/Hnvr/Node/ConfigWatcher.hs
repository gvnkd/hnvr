{-# LANGUAGE OverloadedStrings #-}

-- | Per-host ConfigWatcher (node-side).
--
-- Subscribes to the three command channels that drive the
-- 'Hnvr.Node.CaptureSupervisor':
--
--   * @hnvr.commands.assign.>@ — reassignment decisions from the
--     leader's 'AssignmentCoordinator'. Carries 'AssignPayload' with
--     the full 'CameraSnapshot' (when the camera is enabled) so we can
--     spawn a worker without an extra round-trip.
--   * @hnvr.commands.control.<this_host>.>@ — start/stop/restart
--     directives from the leader (typically emitted on reassignment so
--     the /old/ host can drain gracefully; may also be sent by future
--     admin UI actions like "force-restart worker").
--   * @hnvr.config.cameras.>@ — broadcast on row change. We log the
--     receipt but do NOT dispatch (the assign + control channels cover
--     lifecycle; live config updates land in a follow-up slice and
--     will reuse this channel).
module Hnvr.Node.ConfigWatcher
  ( startConfigWatcher,
  )
where

import Control.Applicative ((<*>))
import Control.Concurrent.Async (async)
import Control.Monad (forever, when)
import Data.Aeson (decodeStrict')
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import Hnvr.Core.CameraSnapshot (CameraSnapshot (..))
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Core.Logging (logInfo, logWarn)
import Hnvr.Nats.Bus (Bus, Message (..))
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Node.CaptureSupervisor
  ( CaptureSupervisor,
    restartCamera,
    startCamera,
    stopCamera,
  )
import Hnvr.Web.CommandTypes
  ( AssignPayload (..),
    ControlPayload (..),
  )

-- | Spawn the subscriber. Reads messages forever in background asyncs
-- (one per subject — nats-queue delivers each on its own thread via
-- the subscription's TChan). @host@ is this node's id, used to filter
-- the control subject to directives aimed at us.
startConfigWatcher :: Bus -> Text -> CaptureSupervisor -> IO ()
startConfigWatcher bus host sup = do
  _ <- async (assignLoop host sup)
  _ <- async (controlLoop host sup)
  _ <- async configLoop
  logInfo
    ( "ConfigWatcher: subscribed to hnvr.commands.assign.>, \
      \hnvr.commands.control."
        <> host
        <> ".>, and hnvr.config.cameras.> as "
        <> host
    )
  where
    assignLoop thisHost supervisor =
      forever $ do
        sub <- Bus.subscribe bus "hnvr.commands.assign.>"
        msg <- Bus.readMessage sub
        handleAssign thisHost supervisor msg

    controlLoop thisHost supervisor =
      forever $ do
        let subject = "hnvr.commands.control." <> thisHost <> ".>"
        sub <- Bus.subscribe bus subject
        msg <- Bus.readMessage sub
        handleControl supervisor msg

    configLoop =
      forever $ do
        sub <- Bus.subscribe bus "hnvr.config.cameras.>"
        msg <- Bus.readMessage sub
        handleConfig msg

-- | Decide whether a 'AssignPayload' is aimed at us and dispatch:
--   * host matches + Just snapshot  → startCamera
--   * host matches + Nothing        → stopCamera (camera disabled)
--   * host doesn't match            → defensive stopCamera (in case we
--     were the previous owner and missed the control.stop)
handleAssign :: Text -> CaptureSupervisor -> Message -> IO ()
handleAssign host sup msg =
  case decodeStrict' (msgPayload msg) :: Maybe AssignPayload of
    Just ap -> do
      let camId = CameraId ap.apCameraId
      if ap.apHost == host
        then case ap.apCamera of
          Just snap -> do
            when (csId snap /= camId) $
              logWarn ("ConfigWatcher: snapshot id mismatch on " <> ap.apSlug)
            startCamera sup snap
          Nothing -> do
            logInfo ("ConfigWatcher: assign " <> ap.apSlug <> " -> " <> ap.apHost <> " (disabled, stopping)")
            stopCamera sup camId
        else do
          -- Defensive: we might be the previous owner and missed the
          -- control.stop. Idempotent — no-op if we don't own it.
          stopCamera sup camId
    Nothing ->
      logWarn ("ConfigWatcher: failed to decode assign payload on " <> msgSubject msg)

-- | Decode a control directive and dispatch start/stop/restart.
--
--   * @stop@    → 'stopCamera' by CameraId.
--   * @restart@ → 'stopCamera' then ask the leader for a fresh
--     snapshot to respawn with. (M1 does NOT auto-respawn here because
--     'ControlPayload' doesn't carry the new snapshot — the leader's
--     restart UX should publish a fresh 'AssignPayload' instead. So
--     @restart@ currently degrades to @stop@.)
--   * @start@   → no-op without a snapshot (same reason; use
--     'AssignPayload' to start a worker).
handleControl :: CaptureSupervisor -> Message -> IO ()
handleControl sup msg =
  case decodeStrict' (msgPayload msg) :: Maybe ControlPayload of
    Just cp -> do
      let camId = CameraId cp.cpCameraId
      case cp.cpAction of
        "stop" -> do
          logInfo ("ConfigWatcher: control stop " <> cp.cpSlug)
          stopCamera sup camId
        "restart" -> do
          logInfo ("ConfigWatcher: control restart " <> cp.cpSlug <> " (degrades to stop; respawn via assign)")
          stopCamera sup camId
        "start" ->
          logInfo ("ConfigWatcher: control start " <> cp.cpSlug <> " (no-op; assign carries snapshot)")
        other ->
          logWarn ("ConfigWatcher: unknown control action " <> other <> " for " <> cp.cpSlug)
    Nothing ->
      logWarn ("ConfigWatcher: failed to decode control payload on " <> msgSubject msg)

-- | Receive a broadcast camera row from the leader's
-- 'Hnvr.Web.ConfigBroadcaster'. M1 logs receipt only — live config
-- updates (RTSP URL rotation, password rotation) without an explicit
-- re-assign will land in a follow-up slice that decodes the row JSON
-- and calls 'restartCamera' with the new 'CameraSnapshot'.
handleConfig :: Message -> IO ()
handleConfig msg = do
  let slug = lastDotToken (msgSubject msg)
  logInfo
    ( "ConfigWatcher: config broadcast for "
        <> slug
        <> " ("
        <> T.pack (show (B.length (msgPayload msg)))
        <> " bytes; live-update dispatch lands in a follow-up slice)"
    )
  where
    lastDotToken s = case T.breakOnEnd "." s of
      ("", _) -> s
      (_, t) -> t
