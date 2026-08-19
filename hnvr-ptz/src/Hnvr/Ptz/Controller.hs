{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Per-PTZ-camera state machine (Phase 5).
--
-- One async thread per PTZ-enabled camera on the host that owns it
-- (spawned by 'Hnvr.Node.CaptureSupervisor' alongside the capture
-- worker). Subscribes @hnvr.commands.ptz.\<slug\>@, executes via the
-- resolved 'OnvifPtz' endpoint, and after every command:
--
--   * publishes a 'PtzStatusMsg' on @hnvr.ptz.status.\<slug\>@ (live UI),
--   * publishes a 'PtzAuditRecord' on @hnvr.ptz.audit@ (the leader's
--     PtzAuditWriter persists it — nodes have no DB access),
--   * replies on the message's @replyTo@ when present (request/reply
--     for @set_preset@ token + @get_presets@ list).
--
-- Idle return-to-home: a 1 s ticker watches the last-activity stamp;
-- when @idle_timeout_s@ elapses after any manual command, the
-- controller issues a home return (source @idle_timeout@) — home
-- preset when configured, absolute origin otherwise.
--
-- State machine (v1 — AutoTracking lands in Phase 7):
--
-- @
--       ┌──────────┐  continuous_move   ┌─────────────┐
--       │   Idle   │───────────────────▶│ ManualMove  │──stop──┐
--       └────▲─────┘                    └─────────────┘        │
--            │ goto_preset ─▶ GoingToPreset                    │
--            │ go_home ─▶ ReturningHome                        │
--            └──────────────── idle tick / next command ◀──────┘
-- @
module Hnvr.Ptz.Controller
  ( PtzControllerConfig (..),
    startPtzController,
    coalesceBatch,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVar, readTVarIO, writeTVar)
import Control.Exception (SomeAsyncException (..), SomeException, fromException, throwIO, try)
import Control.Monad (forM_, forever, when)
import Data.Aeson (Value, decodeStrict', encode, toJSON)
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (isJust, isNothing)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Core.Logging (logError, logInfo, logWarn)
import Hnvr.Core.Metrics (Metrics (..))
import Hnvr.Core.Ptz
import Hnvr.Nats.Bus (Bus, Message (..))
import qualified Hnvr.Nats.Bus as Bus
import qualified Hnvr.Nats.Subjects as Subjects
import Hnvr.Onvif.Client (OnvifError (..))
import Hnvr.Ptz.Onvif (OnvifPtz)
import qualified Hnvr.Ptz.Onvif as Drv

data PtzControllerConfig = PtzControllerConfig
  { pccBus :: !Bus,
    pccSlug :: !Text,
    pccCameraId :: !CameraId,
    pccDriver :: !OnvifPtz,
    pccHomePreset :: !(Maybe PresetToken),
    -- | Seconds of no PTZ activity before returning home. 0 disables.
    pccIdleTimeoutS :: !Int,
    pccMetrics :: !Metrics
  }

-- | Spawn the command loop + idle ticker. The caller owns the returned
-- asyncs (cancel on camera stop). The subscription is taken once;
-- nats-queue re-delivers on reconnect internally.
startPtzController :: PtzControllerConfig -> IO (Async (), Async ())
startPtzController cfg = do
  lastActivity <- newTVarIO Nothing
  -- One blocking GetStatus at startup. Firmwares answering xsi:nil (or
  -- erroring) get position polling DISABLED: on the Hik-OEM floor_2_5
  -- the nil path takes ~4 s per call — after EVERY command that backed
  -- the queue up for seconds (Aug-18 lag report). Supported cameras
  -- answer fast and get a 1 Hz position refresh in the ticker instead.
  (statusSupported, pos0) <- probeStatusSupport cfg.pccDriver
  posCache <- newTVarIO pos0
  now0 <- getCurrentTime
  uiState <- newTVarIO (PtzIdle, "start", now0)
  sub <- Bus.subscribe cfg.pccBus (Subjects.commandPtz cfg.pccSlug)
  cmdLoop <- async $ forever $ do
    first <- Bus.readMessage sub
    rest <- Bus.drainSubscription sub
    let plan = coalesceBatch (first : rest)
        dropped = length rest + 1 - length plan
    when (dropped > 0) $
      logInfo
        ( "PtzController "
            <> cfg.pccSlug
            <> ": dropped "
            <> tshow dropped
            <> " superseded command(s)"
        )
    forM_ plan $ \msg -> guarded "" (handleMessage cfg lastActivity uiState posCache msg)
  ticker <- async $ forever $ do
    threadDelay 1_000_000
    guarded " idle tick" (idleTick cfg lastActivity uiState posCache)
    when statusSupported $
      guarded " status refresh" (refreshPosition cfg uiState posCache)
  logInfo ("PtzController: started for " <> cfg.pccSlug)
  pure (cmdLoop, ticker)
  where
    tshow :: (Show a) => a -> Text
    tshow = T.pack . show
    guarded label act = do
      r <- try act
      case r of
        Right () -> pure ()
        Left (e :: SomeException) -> case fromException e of
          Just (SomeAsyncException _) -> throwIO e
          Nothing -> logError ("PtzController " <> cfg.pccSlug <> label <> ": " <> T.pack (show e))

-- | Given the pending batch (oldest first), pick what to execute:
-- every request/reply message (a caller is blocked waiting for an
-- answer) plus only the NEWEST fire-and-forget message. Pad intents
-- supersede each other; executing a stale one late is the "camera
-- replays old commands" lag (Aug-18 report). Dropped messages are not
-- audited — they never executed.
coalesceBatch :: [Message] -> [Message]
coalesceBatch msgs =
  [m | (i, m) <- indexed, isJust (msgReplyTo m) || Just i == lastFf]
  where
    indexed = zip [0 ..] msgs
    lastFf = case [i | (i, m) <- indexed, isNothing (msgReplyTo m)] of
      [] -> Nothing
      is -> Just (maximum is)

-- | One received command: decode → execute → status + audit + reply.
handleMessage ::
  PtzControllerConfig ->
  TVar (Maybe UTCTime) ->
  TVar (PtzState, Text, UTCTime) ->
  TVar (Maybe PtzPosition) ->
  Message ->
  IO ()
handleMessage cfg lastActivity uiState posCache msg =
  case decodeStrict' (msgPayload msg) of
    Nothing -> do
      logWarn ("PtzController " <> cfg.pccSlug <> ": undecodable command payload")
      replyTo msg (PtzReplyError "undecodable command payload")
    Just cmdMsg -> do
      now <- getCurrentTime
      atomically (writeTVar lastActivity (Just now))
      (result, mErr) <- execute cfg (pcmCommand cmdMsg)
      let ok = isNothing mErr
          cmdName = commandName (pcmCommand cmdMsg)
      mPtzCommand cfg.pccMetrics cfg.pccSlug cmdName (ptzSourceText (pcmSource cmdMsg))
      publishStatus cfg uiState posCache (stateAfter (pcmCommand cmdMsg)) cmdName now
      publishAudit cfg cmdMsg ok mErr
      replyTo msg $ case (mErr, result) of
        (Just e, _) -> PtzReplyError e
        (Nothing, v) -> PtzReplyOk v
  where
    replyTo m r = case msgReplyTo m of
      Nothing -> pure ()
      Just inbox -> Bus.reply cfg.pccBus (Just inbox) (BL.toStrict (encode r))

-- | Execute one command against the camera. Returns the reply payload
-- ('Just' for set_preset/get_presets) and an error text on failure.
execute :: PtzControllerConfig -> PtzCommand -> IO (Maybe Value, Maybe Text)
execute cfg cmd = do
  started <- getCurrentTime
  res <- run cmd
  finished <- getCurrentTime
  mPtzCommandSeconds cfg.pccMetrics cfg.pccSlug (realToFrac (diffUTCTime finished started))
  pure $ case res of
    Left e -> (Nothing, Just e)
    Right v -> (v, Nothing)
  where
    drv = cfg.pccDriver
    run :: PtzCommand -> IO (Either Text (Maybe Value))
    run (CmdContinuousMove v toMs) = noPayload <$> Drv.continuousMove drv v toMs
    run (CmdStop axes) = noPayload <$> Drv.stop drv axes
    run (CmdGotoPreset t) = noPayload <$> Drv.gotoPreset drv t
    run CmdGoHome = case cfg.pccHomePreset of
      Just t -> noPayload <$> Drv.gotoPreset drv t
      Nothing -> noPayload <$> Drv.absoluteMove drv (PtzPosition 0 0 0)
    run (CmdAbsoluteMove p) = noPayload <$> Drv.absoluteMove drv p
    run (CmdSetPreset n) = do
      r <- Drv.setPreset drv n
      pure $ case r of
        Left e -> Left (errText e)
        Right token -> Right (Just (toJSON token))
    run (CmdRemovePreset t) = noPayload <$> Drv.removePreset drv t
    run CmdGetPresets = do
      r <- Drv.getPresets drv
      pure $ case r of
        Left e -> Left (errText e)
        Right presets -> Right (Just (toJSON presets))
    noPayload :: Either OnvifError () -> Either Text (Maybe Value)
    noPayload (Left e) = Left (errText e)
    noPayload (Right ()) = Right Nothing

-- | Status broadcast after every command. Position comes from the
-- cache — NO per-command GetStatus (see 'probeStatusSupport').
publishStatus ::
  PtzControllerConfig ->
  TVar (PtzState, Text, UTCTime) ->
  TVar (Maybe PtzPosition) ->
  PtzState ->
  Text ->
  UTCTime ->
  IO ()
publishStatus cfg uiState posCache st cmdName now = do
  mPos <- readTVarIO posCache
  atomically (writeTVar uiState (st, cmdName, now))
  Bus.publishJson cfg.pccBus (Subjects.ptzStatus cfg.pccSlug) (statusMsg st mPos cmdName now)

statusMsg :: PtzState -> Maybe PtzPosition -> Text -> UTCTime -> PtzStatusMsg
statusMsg st mPos cmdName now =
  PtzStatusMsg
    { psmState = st,
      psmPosition = mPos,
      psmLastCommand = cmdName,
      psmLastCommandAt = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
    }

-- | Startup GetStatus probe: @(supported, initialPosition)@. A nil or
-- erroring GetStatus marks the camera unsupported — the ticker then
-- never calls it again (a ~4 s blocking nil path would stall every
-- status refresh otherwise).
probeStatusSupport :: OnvifPtz -> IO (Bool, Maybe PtzPosition)
probeStatusSupport drv = do
  r <- Drv.getStatus drv
  pure $ case r of
    Right mp -> (isJust mp, mp)
    Left _ -> (False, Nothing)

-- | 1 Hz position refresh for cameras whose GetStatus is fast
-- ('probeStatusSupport'). Republishes the last UI state with a fresh
-- position so the status feed stays alive between commands.
refreshPosition ::
  PtzControllerConfig -> TVar (PtzState, Text, UTCTime) -> TVar (Maybe PtzPosition) -> IO ()
refreshPosition cfg uiState posCache = do
  r <- Drv.getStatus cfg.pccDriver
  case r of
    Left _ -> pure ()
    Right mp -> do
      (st, cmdName, at) <- atomically $ do
        writeTVar posCache mp
        readTVar uiState
      Bus.publishJson cfg.pccBus (Subjects.ptzStatus cfg.pccSlug) (statusMsg st mp cmdName at)

publishAudit :: PtzControllerConfig -> PtzCommandMsg -> Bool -> Maybe Text -> IO ()
publishAudit cfg cmdMsg ok mErr =
  Bus.publishJson cfg.pccBus Subjects.ptzAudit $
    PtzAuditRecord
      { parCameraId = T.pack (show (unCameraId cfg.pccCameraId)),
        parUserId = pcmUserId cmdMsg,
        parCommand = commandName (pcmCommand cmdMsg),
        parArgs = commandArgs (pcmCommand cmdMsg),
        parSource = pcmSource cmdMsg,
        parDurationMs = pcmDurationMs cmdMsg,
        parOk = ok,
        parError = mErr
      }

-- | Idle ticker: when the timeout elapsed since the last command and a
-- home return is configured (or an origin fallback applies), issue it
-- once (source @idle_timeout@) and clear the activity stamp.
idleTick ::
  PtzControllerConfig ->
  TVar (Maybe UTCTime) ->
  TVar (PtzState, Text, UTCTime) ->
  TVar (Maybe PtzPosition) ->
  IO ()
idleTick cfg lastActivity uiState posCache = do
  mLast <- readTVarIO lastActivity
  case (mLast, cfg.pccIdleTimeoutS > 0) of
    (Just last', True) -> do
      now <- getCurrentTime
      when (diffUTCTime now last' > fromIntegral cfg.pccIdleTimeoutS) $ do
        atomically (writeTVar lastActivity Nothing)
        let cmdMsg =
              PtzCommandMsg
                { pcmCommand = CmdGoHome,
                  pcmSource = SrcIdleTimeout,
                  pcmUserId = Nothing,
                  pcmDurationMs = Nothing
                }
        (_result, mErr) <- execute cfg CmdGoHome
        let ok = isNothing mErr
        case mErr of
          Nothing -> mPtzCommand cfg.pccMetrics cfg.pccSlug "go_home" "idle_timeout"
          Just e -> logWarn ("PtzController " <> cfg.pccSlug <> ": idle return-home failed: " <> e)
        publishStatus cfg uiState posCache PtzReturningHome "go_home" now
        publishAudit cfg cmdMsg ok mErr
    _ -> pure ()

errText :: OnvifError -> Text
errText (OnvifTransportError t) = "transport: " <> t
errText (OnvifHttpError st t) = "HTTP " <> T.pack (show st) <> ": " <> t
errText (OnvifFault t) = "SOAP fault: " <> t
errText (OnvifParseError t) = "parse: " <> t
