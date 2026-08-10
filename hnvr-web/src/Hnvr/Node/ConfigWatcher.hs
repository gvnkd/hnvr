{-# LANGUAGE OverloadedStrings #-}

-- | Per-host ConfigWatcher (node-side).
--
-- Subscribes to the two command channels targeted at this host:
--
--   * @hnvr.commands.assign.>@ — reassignment decisions from the
--     leader's 'AssignmentCoordinator'. Tells us which cameras we now own.
--   * @hnvr.commands.control.<this_host>.>@ — start/stop/restart
--     directives from the leader (typically emitted on reassignment so
--     the /old/ host can drain gracefully; may also be sent by future
--     admin UI actions like "force-restart worker").
--
-- Both handlers are stubs for Phase 2: they decode + log. Phase 3 wires
-- them to the CaptureSupervisor that will own per-camera worker asyncs
-- inside the node process (today the CaptureWorker runs as a separate
-- CLI binary, so there's nothing to dispatch against yet).
module Hnvr.Node.ConfigWatcher
  ( startConfigWatcher,
  )
where

import Control.Applicative ((<*>))
import Control.Concurrent.Async (async)
import Control.Monad (forever, when)
import Data.Aeson (FromJSON (..), decodeStrict')
import Data.Aeson.Types (withObject, (.:))
import qualified Data.ByteString as B
import Data.Text (Text)
import qualified Data.Text as T
import Hnvr.Core.Logging (logInfo, logWarn)
import Hnvr.Nats.Bus (Bus, Message (..))
import qualified Hnvr.Nats.Bus as Bus

-- | Wire payload for @hnvr.commands.assign.<slug>@.
data AssignMsg = AssignMsg
  { amSlug :: !Text,
    amHost :: !Text
  }
  deriving (Show)

instance FromJSON AssignMsg where
  parseJSON = withObject "AssignMsg" $ \o ->
    AssignMsg
      <$> o .: "slug"
      <*> o .: "host"

-- | Wire payload for @hnvr.commands.control.<host>.<cam>.<action>@.
-- Mirrors 'Hnvr.Web.AssignmentCoordinator.ControlMsg'.
data ControlMsg = ControlMsg
  { cmSlug :: !Text,
    cmAction :: !Text
  }
  deriving (Show)

instance FromJSON ControlMsg where
  parseJSON = withObject "ControlMsg" $ \o ->
    ControlMsg
      <$> o .: "slug"
      <*> o .: "action"

-- | Spawn the subscriber. Reads messages forever in background asyncs
-- (one per subject — nats-queue delivers each on its own thread via
-- the subscription's TChan). @host@ is this node's id, used to filter
-- the control subject to directives aimed at us.
startConfigWatcher :: Bus -> Text -> IO ()
startConfigWatcher bus host = do
  _ <- async assignLoop
  _ <- async (controlLoop host)
  _ <- async configLoop
  logInfo
    ( "ConfigWatcher: subscribed to hnvr.commands.assign.>, \
      \hnvr.commands.control."
        <> host
        <> ".>, and hnvr.config.cameras.> as "
        <> host
    )
  where
    assignLoop =
      forever $ do
        sub <- Bus.subscribe bus "hnvr.commands.assign.>"
        msg <- Bus.readMessage sub
        handleAssign host msg

    controlLoop thisHost =
      forever $ do
        let subject = "hnvr.commands.control." <> thisHost <> ".>"
        sub <- Bus.subscribe bus subject
        msg <- Bus.readMessage sub
        handleControl msg

    configLoop =
      forever $ do
        sub <- Bus.subscribe bus "hnvr.config.cameras.>"
        msg <- Bus.readMessage sub
        handleConfig msg

-- | Decode the assign message and decide whether this camera is now
-- ours. Slice 5 stub: just log. Slice 6+: start/stop CaptureSupervisor.
handleAssign :: Text -> Message -> IO ()
handleAssign host msg =
  case decodeStrict' (msgPayload msg) :: Maybe AssignMsg of
    Just am -> do
      let ours = am.amHost == host
      logInfo
        ( "ConfigWatcher: assign "
            <> am.amSlug
            <> " -> "
            <> am.amHost
            <> (if ours then " (ours)" else " (not ours)")
        )
    Nothing ->
      logWarn ("ConfigWatcher: failed to decode assign payload on " <> msgSubject msg)

-- | Decode a control directive. Slice 5 stub: just log. Phase 3 will
-- dispatch start/stop/restart to the CaptureSupervisor owning the
-- named camera.
handleControl :: Message -> IO ()
handleControl msg =
  case decodeStrict' (msgPayload msg) :: Maybe ControlMsg of
    Just cm ->
      when (cm.cmAction == "start" || cm.cmAction == "stop" || cm.cmAction == "restart") $
        logInfo
          ( "ConfigWatcher: control "
              <> cm.cmSlug
              <> " "
              <> cm.cmAction
              <> " (CaptureSupervisor dispatch lands in Phase 3) on "
              <> msgSubject msg
          )
    Nothing ->
      logWarn ("ConfigWatcher: failed to decode control payload on " <> msgSubject msg)

-- | Receive a broadcast camera row from the leader's
-- 'Hnvr.Web.ConfigBroadcaster'. The payload is the raw JSON the
-- 'Camera' record serializes to. Phase 3 will decode + populate an
-- @IORef (Map CameraId Camera)@ for the analyzer pipeline; Phase 2
-- just logs receipt so we can verify the channel is wired.
--
-- The subject token after the last dot is the slug (per
-- 'Hnvr.Nats.Subjects.configCameras'); we extract it for the log line.
handleConfig :: Message -> IO ()
handleConfig msg = do
  let slug = lastDotToken (msgSubject msg)
  logInfo
    ( "ConfigWatcher: config broadcast for "
        <> slug
        <> " ("
        <> T.pack (show (B.length (msgPayload msg)))
        <> " bytes; Phase 3 will populate the IORef)"
    )
  where
    lastDotToken s = case T.breakOnEnd "." s of
      ("", _) -> s
      (_, t) -> t
