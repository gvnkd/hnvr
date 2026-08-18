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
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (Async, async)
import Control.Concurrent.STM (TVar, atomically, newTVarIO, readTVarIO, writeTVar)
import Control.Exception (SomeAsyncException (..), SomeException, fromException, throwIO, try)
import Control.Monad (forever, when)
import Data.Aeson (Value, decodeStrict', encode, toJSON)
import qualified Data.ByteString.Lazy as BL
import Data.Either (fromRight)
import Data.Maybe (isNothing)
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
  sub <- Bus.subscribe cfg.pccBus (Subjects.commandPtz cfg.pccSlug)
  cmdLoop <- async $ forever $ do
    msg <- Bus.readMessage sub
    r <- try (handleMessage cfg lastActivity msg)
    case r of
      Right () -> pure ()
      Left (e :: SomeException) -> case fromException e of
        Just (SomeAsyncException _) -> throwIO e
        Nothing -> logError ("PtzController " <> cfg.pccSlug <> ": " <> T.pack (show e))
  ticker <- async $ forever $ do
    threadDelay 1_000_000
    r <- try (idleTick cfg lastActivity)
    case r of
      Right () -> pure ()
      Left (e :: SomeException) -> case fromException e of
        Just (SomeAsyncException _) -> throwIO e
        Nothing -> logError ("PtzController " <> cfg.pccSlug <> " idle tick: " <> T.pack (show e))
  logInfo ("PtzController: started for " <> cfg.pccSlug)
  pure (cmdLoop, ticker)

-- | One received command: decode → execute → status + audit + reply.
handleMessage :: PtzControllerConfig -> TVar (Maybe UTCTime) -> Message -> IO ()
handleMessage cfg lastActivity msg =
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
      publishStatus cfg (stateAfter (pcmCommand cmdMsg)) cmdName now
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

-- | Status broadcast after every command. Position readout is
-- best-effort — a failing GetStatus must not mask the command result.
publishStatus :: PtzControllerConfig -> PtzState -> Text -> UTCTime -> IO ()
publishStatus cfg st cmdName now = do
  mPos <- fromRight Nothing <$> Drv.getStatus cfg.pccDriver
  let msg =
        PtzStatusMsg
          { psmState = st,
            psmPosition = mPos,
            psmLastCommand = cmdName,
            psmLastCommandAt = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
          }
  Bus.publishJson cfg.pccBus (Subjects.ptzStatus cfg.pccSlug) msg

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
idleTick :: PtzControllerConfig -> TVar (Maybe UTCTime) -> IO ()
idleTick cfg lastActivity = do
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
        publishStatus cfg PtzReturningHome "go_home" now
        publishAudit cfg cmdMsg ok mErr
    _ -> pure ()

errText :: OnvifError -> Text
errText (OnvifTransportError t) = "transport: " <> t
errText (OnvifHttpError st t) = "HTTP " <> T.pack (show st) <> ": " <> t
errText (OnvifFault t) = "SOAP fault: " <> t
errText (OnvifParseError t) = "parse: " <> t
