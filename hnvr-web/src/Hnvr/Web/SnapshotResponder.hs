{-# LANGUAGE OverloadedRecordDot #-}
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
-- The responder is also the duplicate-worker arbiter
-- ('Hnvr.Core.HostClaim'): the leader binary already runs the full
-- node role for its own host, so a snapshot request for that host from
-- anything NOT marked @leader: true@ in the request payload is denied
-- (empty batch, @claimed: false@). Running @hnvr-node@ on the leader
-- host was the 2026-08-15 double-record bug.
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
import Data.Aeson (Value (..), decodeStrict, encode)
import qualified Data.Aeson.KeyMap as KM
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.List (foldl')
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Database.PostgreSQL.Simple (Only (..))
import qualified Database.PostgreSQL.Simple as PG
import Database.PostgreSQL.Simple.FromRow (FromRow (..), field)
import Database.PostgreSQL.Simple.Types (Binary (..), PGArray (..))
import Hnvr.Core.CameraSnapshot
  ( CameraSnapshot (..),
    CameraSnapshotBatch (..),
    PtzSnapshot (..),
    RuleSnapshot (..),
    audioInputRateHz,
    transportFromText,
  )
import Hnvr.Core.HostClaim (ClaimDecision (..), decideSnapshotClaim)
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Core.Logging (logError, logInfo, logWarn)
import Hnvr.Core.Onvif (hostFromRtspUrl)
import Hnvr.Nats.Bus (Bus, Message (..))
import qualified Hnvr.Nats.Bus as Bus
import qualified System.Environment as Env
import Web.Controller.Support.Crypto (decryptPassword)

-- | Spawn the responder in a background 'async'. Subscribes to
-- @hnvr.commands.snapshot.>@ and replies to each message's @replyTo@
-- with a 'CameraSnapshotBatch' JSON payload.
startSnapshotResponder :: Bus -> IO ()
startSnapshotResponder bus = do
  _ <- async loop
  logInfo "SnapshotResponder: subscribed to hnvr.commands.snapshot.>"
  where
    loop = do
      sub <- Bus.subscribe bus "hnvr.commands.snapshot.>"
      forever $ do
        msg <- Bus.readMessage sub
        handleRequest bus msg
          `catch` \(e :: SomeException) ->
            logError ("SnapshotResponder: handler failed: " <> T.pack (show e))

-- | Extract the target host from the subject, arbitrate the claim
-- ('decideSnapshotClaim' — an external node must never be granted the
-- leader's own host), fetch assigned cameras, encode as
-- 'CameraSnapshotBatch', reply via the message's @replyTo@.
-- Silently drops messages with no @replyTo@ (malformed requester).
handleRequest :: Bus -> Message -> IO ()
handleRequest bus msg =
  case msgReplyTo msg of
    Nothing -> logWarn ("SnapshotResponder: no replyTo on " <> msgSubject msg <> ", dropping")
    Just replyTo -> do
      let host = lastDotToken (msgSubject msg)
      leaderHost <- maybe "hnvr-2" T.pack <$> Env.lookupEnv "HNVR_HOST"
      case decideSnapshotClaim leaderHost (isLeaderRequest msg) host of
        ClaimDeniedLeaderHost -> do
          let payload = BL.toStrict (encode CameraSnapshotBatch {csbCameras = [], csbClaimed = False})
          Bus.reply bus (Just replyTo) payload
          logWarn
            ( "SnapshotResponder: DENIED snapshot claim for leader host "
                <> host
                <> " (an hnvr-node on the leader host double-records every camera — kill it)"
            )
        ClaimGranted -> do
          cams <- fetchAssignedCameras host
          let batch = CameraSnapshotBatch {csbCameras = cams, csbClaimed = True}
              payload = BL.toStrict (encode batch)
          Bus.reply bus (Just replyTo) payload
          logInfo ("SnapshotResponder: replied to " <> host <> " with " <> T.pack (show (length cams)) <> " camera(s)")
  where
    lastDotToken s = case T.breakOnEnd "." s of
      ("", _) -> s
      (_, t) -> t

-- | The leader marks its own bootstrap request with @leader: true@.
-- Anything undecodable is treated as external (deny-by-default for the
-- leader host; spoofing is out of threat model on the LAN — this guards
-- against the accidental double-run, not malice).
isLeaderRequest :: Message -> Bool
isLeaderRequest msg =
  case decodeStrict (msgPayload msg) of
    Just (Object o) -> KM.lookup "leader" o == Just (Bool True)
    _ -> False

-- | One-shot PG connection: full camera rows (incl. PTZ columns, home
-- preset token via LEFT JOIN) WHERE assigned_host = ? AND enabled.
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
        "SELECT c.id, c.slug, c.rtsp_url, c.rtsp_transport, c.record_audio, c.rtsp_sub_url, c.use_substream_for_analysis, c.substream_width, c.substream_height, c.analysis_fps, c.model_name, c.ptz_enabled, c.mgmt_proto, c.host, c.onvif_port, c.username, c.password_enc, c.password_nonce, c.ptz_profile_token, c.ptz_idle_timeout_s, hp.onvif_token, c.snapshot_interval_sec, c.audio_encoding, c.audio_sample_rate_khz FROM cameras c LEFT JOIN ptz_presets hp ON hp.id = c.ptz_home_preset_id WHERE c.assigned_host = ? AND c.enabled = TRUE"
        (Only host)
    ruleRows <-
      PG.query_
        conn
        "SELECT id, camera_id, kind::text, geometry, classes, cooldown_ms, clip_preroll_sec, clip_postroll_sec, clip_retention_hours FROM rules WHERE enabled = TRUE"
    let rulesByCam = foldl' (\m r@(_rid, cid, _, _, _, _, _, _, _) -> M.insertWith (++) (cid :: UUID) [mkRuleSnap r] m) M.empty ruleRows
    concat <$> mapM (mkSnapshot rulesByCam) rows
  where
    mkRuleSnap (rid, _cid, kind, geometry, PGArray classes, cooldown, pre, post, retHours) =
      RuleSnapshot
        { rsId = UUID.toText rid,
          rsKind = kind,
          rsGeometry = geometry,
          rsClasses = map fromIntegral classes,
          rsCooldownMs = fromIntegral cooldown,
          rsClipPrerollSec = fromIntegral pre,
          rsClipPostrollSec = fromIntegral post,
          rsClipRetentionHours = fmap fromIntegral retHours
        }
    mkSnapshot rulesByCam row =
      case transportFromText row.crTransport of
        Just tr -> do
          ptz <- mkPtz row
          pure
            [ CameraSnapshot
                { csId = CameraId row.crId,
                  csSlug = row.crSlug,
                  csRtspUrl = row.crRtspUrl,
                  csTransport = tr,
                  csRecordAudio = row.crRecordAudio,
                  csRtspSubUrl = row.crSubUrl,
                  csUseSubstream = row.crUseSub,
                  csSubWidth = fromIntegral <$> row.crSubW,
                  csSubHeight = fromIntegral <$> row.crSubH,
                  csAnalysisFps = fromIntegral row.crFps,
                  csSnapshotIntervalSec = fromIntegral row.crSnapshotIntervalSec,
                  csModelName = row.crModelName,
                  csRules = M.findWithDefault [] row.crId rulesByCam,
                  csPtz = ptz,
                  csAudioInputRateHz = audioInputRateHz row.crAudioEncoding row.crAudioRateKhz
                }
            ]
        Nothing -> pure []

-- | 24 columns exceeds pg-simple's tuple 'FromRow' instances
-- (pitfall #122 class), so the row lands in a record via explicit
-- 'field' reads.
data CamRow = CamRow
  { crId :: !UUID,
    crSlug :: !Text,
    crRtspUrl :: !Text,
    crTransport :: !Text,
    crRecordAudio :: !Bool,
    crSubUrl :: !(Maybe Text),
    crUseSub :: !Bool,
    crSubW :: !(Maybe Int),
    crSubH :: !(Maybe Int),
    crFps :: !Int,
    crModelName :: !Text,
    crPtzEnabled :: !Bool,
    crMgmtProto :: !Text,
    crHost :: !(Maybe Text),
    crOnvifPort :: !(Maybe Int),
    crUsername :: !(Maybe Text),
    crPasswordEnc :: !(Maybe (Binary ByteString)),
    crPasswordNonce :: !(Maybe (Binary ByteString)),
    crPtzProfileToken :: !(Maybe Text),
    crPtzIdleTimeoutS :: !Int,
    crHomePresetToken :: !(Maybe Text),
    crSnapshotIntervalSec :: !Int,
    crAudioEncoding :: !(Maybe Text),
    crAudioRateKhz :: !(Maybe Int)
  }

instance FromRow CamRow where
  fromRow =
    CamRow
      <$> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field
      <*> field

-- | PTZ projection, mirroring
-- 'Hnvr.Web.CommandTypes.ptzSnapshotFor' (keep both in sync): ONVIF
-- proto only, host falls back to the RTSP URL authority, decryptable
-- password required.
mkPtz :: CamRow -> IO (Maybe PtzSnapshot)
mkPtz row
  | not row.crPtzEnabled = pure Nothing
  | row.crMgmtProto /= "onvif" = pure Nothing
  | otherwise = case (mHost, row.crOnvifPort, nonEmpty row.crUsername, row.crPtzProfileToken) of
      (Just host', Just port', Just user, Just profileToken) -> do
        mPw <- decryptPassword row.crPasswordEnc row.crPasswordNonce
        pure $ case mPw of
          Nothing -> Nothing
          Just pw ->
            Just
              PtzSnapshot
                { psHost = host',
                  psOnvifPort = port',
                  psUsername = user,
                  psPassword = pw,
                  psProfileToken = profileToken,
                  psHomePresetToken = row.crHomePresetToken,
                  psIdleTimeoutS = row.crPtzIdleTimeoutS
                }
      _ -> pure Nothing
  where
    mHost = case row.crHost of
      Just h | not (T.null h) -> Just h
      _ -> hostFromRtspUrl row.crRtspUrl
    nonEmpty (Just t) | not (T.null t) = Just t
    nonEmpty _ = Nothing

-- | Default DB URL matches IHP's. Real deployments set DATABASE_URL.
defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"
