{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Node-side event-clip recorder (separated event video store).
--
-- One 'OpenClip' per camera at a time, shared across that camera's
-- clip-enabled rules:
--
--   * 'onRuleFired' (called from the analysis sink) OPENS a clip when
--     no clip is open: fragments are snapshotted out of the camera's
--     'Hnvr.Capture.RingBuffer' for @[eventTs - preroll, eventTs]@.
--   * A subsequent fire while a clip is open EXTENDS it: the deadline
--     moves to @eventTs + postroll@, newly-arrived fragments since the
--     last snapshot are appended, and the retention keeps the max of
--     all participating rules.
--   * 'startClipTicker' closes clips whose deadline has passed:
--     uploads @init.mp4@ + fragments under
--     @\<slug\>/clips/\<ts\>/@ ('Hnvr.Core.Clip') and publishes a
--     'ClipReady' on @hnvr.events@ for the leader's EventWriter.
--
-- Snapshot-on-open/extend (rather than streaming-append) keeps the
-- writer/reader concurrency trivial: the ring buffer is only ever
-- read through short STM snapshots, and the watermark ('ocLastSnap')
-- guarantees full coverage even when rule cooldowns make fires sparse
-- — the buffer is sized @maxPre + maxPost + margin@ so everything
-- between open and close is still buffered at close time.
module Hnvr.Node.ClipRecorder
  ( -- * Config projection
    ClipCfg (..),
    clipCfgs,
    bufferWindowSec,

    -- * State
    ClipState,
    OpenClip (..),
    newClipState,
    registerBuffer,
    unregisterCamera,

    -- * Event hook
    onRuleFired,

    -- * Closing
    startClipTicker,
    closeCameraClip,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (async)
import Control.Concurrent.STM (TVar, newTVarIO, readTVarIO)
import Control.Exception (SomeAsyncException (..), SomeException, fromException, throwIO, try)
import Control.Monad (forM_, forever, void)
import Data.ByteString (ByteString)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Maybe (mapMaybe)
import Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, addUTCTime, getCurrentTime)
import Hnvr.Capture.RingBuffer (RingBuffer, RingEntry (..))
import qualified Hnvr.Capture.RingBuffer as RB
import Hnvr.Capture.Worker (CaptureConfig (..))
import Hnvr.Core.CameraSnapshot (RuleSnapshot (..))
import Hnvr.Core.Clip (clipDurationSec, clipFragKey, clipInitKey, clipPrefix)
import Hnvr.Core.Event (ClipReady (..))
import Hnvr.Core.Id (CameraId)
import Hnvr.Core.Logging (logError, logInfo, logWarn)
import qualified Hnvr.Nats.Bus as Bus
import qualified Hnvr.Nats.Subjects as Subjects
import Hnvr.Storage.S3 (putObjectBytes)
import Network.Minio (defaultPutObjectOptions, pooContentType)

-- | Per-rule clip config projected from the wire snapshot. Presence in
-- the 'clipCfgs' map means clip recording is ENABLED for that rule.
data ClipCfg = ClipCfg
  { cfgPrerollSec :: !Int,
    cfgPostrollSec :: !Int,
    cfgRetentionHours :: !Int
  }
  deriving stock (Eq, Show)

-- | Clip-enabled rules of one camera, keyed by rule id (text UUID).
clipCfgs :: [RuleSnapshot] -> Map Text ClipCfg
clipCfgs snaps = M.fromList (mapMaybe mk snaps)
  where
    mk s = case rsClipRetentionHours s of
      Nothing -> Nothing
      Just retH -> Just (rsId s, ClipCfg (rsClipPrerollSec s) (rsClipPostrollSec s) retH)

-- | Ring-buffer window for a camera: @maxPre + maxPost + margin@.
-- 'Nothing' when no rule has clips enabled — the supervisor then
-- creates no buffer at all (zero per-fragment overhead).
bufferWindowSec :: [RuleSnapshot] -> Maybe Int
bufferWindowSec snaps =
  case [ (rsClipPrerollSec s, rsClipPostrollSec s)
       | s <- snaps,
         Just _ <- [rsClipRetentionHours s]
       ] of
    [] -> Nothing
    ps -> Just (maximum (map fst ps) + maximum (map snd ps) + clipMarginSec)

-- | Extra seconds of buffer headroom over @pre + post@: covers the
-- 1 s close-tick latency and wall-clock jitter between the frame
-- timestamp domain and the fragment arrival domain.
clipMarginSec :: Int
clipMarginSec = 10

-- | An open (still-extending) clip for one camera.
data OpenClip = OpenClip
  { ocSlug :: !Text,
    -- | Rule whose fire opened the clip.
    ocRuleId :: !Text,
    -- | Clip start = first event ts minus that rule's pre-roll.
    ocStartedAt :: !UTCTime,
    -- | Close deadline = latest event ts plus its rule's post-roll.
    ocDeadline :: !UTCTime,
    -- | Max retention across all rules that fired into this clip.
    ocRetentionHours :: !Int,
    -- | Accumulated fragments, ascending by 'reStart'.
    ocFrags :: !(Seq RingEntry),
    -- | Latest init segment seen by the buffer at open time.
    ocInit :: !(Maybe ByteString),
    -- | Watermark for incremental snapshots: extensions and the close
    -- collect buffer entries with @reStart >= ocLastSnap@. Boundary
    -- duplicates are harmless — identical bytes overwrite the same S3
    -- key.
    ocLastSnap :: !UTCTime
  }

-- | Process-wide clip state: per-camera ring buffers (shared with the
-- capture workers) and the open-clip map.
data ClipState = ClipState
  { clsBufs :: !(IORef (Map CameraId (TVar RingBuffer))),
    clsOpen :: !(IORef (Map CameraId OpenClip))
  }

newClipState :: IO ClipState
newClipState = ClipState <$> newIORef M.empty <*> newIORef M.empty

-- | Create + register a ring buffer for a camera. The returned 'TVar'
-- goes into the worker's 'Hnvr.Capture.Worker.ccClipBuffer'.
registerBuffer :: ClipState -> CameraId -> Int -> IO (TVar RingBuffer)
registerBuffer st camId windowSecs = do
  buf <- newTVarIO (RB.empty windowSecs)
  atomicModifyIORef' st.clsBufs (\m -> (M.insert camId buf m, ()))
  pure buf

-- | Drop a camera's buffer (on stop). Any open clip is closed
-- separately via 'closeCameraClip'.
unregisterCamera :: ClipState -> CameraId -> IO ()
unregisterCamera st camId =
  atomicModifyIORef' st.clsBufs (\m -> (M.delete camId m, ()))

-- | Analysis-sink hook: a rule fired at @evTs@. Opens or extends the
-- camera's clip when the rule is clip-enabled. Never throws — clip
-- recording must not kill the analyzer loop.
onRuleFired ::
  ClipState ->
  CameraId ->
  Text ->
  Map Text ClipCfg ->
  Text ->
  UTCTime ->
  IO ()
onRuleFired st camId slug cfgs ruleId evTs =
  case M.lookup ruleId cfgs of
    Nothing -> pure ()
    Just cfg -> do
      mBuf <- M.lookup camId <$> readIORef st.clsBufs
      forM_ mBuf $ \bufTVar -> do
        buf <- readTVarIO bufTVar
        atomicModifyIORef' st.clsOpen $ \open ->
          case M.lookup camId open of
            Nothing ->
              let from = addUTCTime (negate (fromIntegral cfg.cfgPrerollSec)) evTs
                  clip =
                    OpenClip
                      { ocSlug = slug,
                        ocRuleId = ruleId,
                        ocStartedAt = from,
                        ocDeadline = addUTCTime (fromIntegral cfg.cfgPostrollSec) evTs,
                        ocRetentionHours = cfg.cfgRetentionHours,
                        ocFrags = Seq.fromList (RB.window from evTs buf),
                        ocInit = RB.initBytes buf,
                        ocLastSnap = evTs
                      }
               in (M.insert camId clip open, ())
            Just oc ->
              let newFrags = Seq.fromList (RB.window oc.ocLastSnap evTs buf)
                  oc' =
                    oc
                      { ocDeadline =
                          max
                            oc.ocDeadline
                            (addUTCTime (fromIntegral cfg.cfgPostrollSec) evTs),
                        ocRetentionHours = max oc.ocRetentionHours cfg.cfgRetentionHours,
                        ocFrags = oc.ocFrags <> newFrags,
                        ocLastSnap = max oc.ocLastSnap evTs
                      }
               in (M.insert camId oc' open, ())

-- | 1 s ticker: closes clips whose deadline passed. Started once per
-- supervisor.
startClipTicker :: CaptureConfig -> ClipState -> IO ()
startClipTicker cfg st = void $ async $ forever $ do
  threadDelay 1_000_000
  closeExpired cfg st

-- | Close any open clip for a camera (camera stop / restart). Uploads
-- whatever has been accumulated; no-op when nothing is open.
closeCameraClip :: CaptureConfig -> ClipState -> CameraId -> IO ()
closeCameraClip cfg st camId = do
  mClip <- atomicModifyIORef' st.clsOpen (\m -> (M.delete camId m, M.lookup camId m))
  forM_ mClip $ \oc ->
    closeOne cfg st camId oc
      `catchClip` \e ->
        logError ("ClipRecorder: close failed for " <> oc.ocSlug <> ": " <> T.pack (show e))

-- | Close every clip whose deadline is in the past. Errors are caught
-- per clip — a bad upload must not stall the ticker.
closeExpired :: CaptureConfig -> ClipState -> IO ()
closeExpired cfg st = do
  now <- getCurrentTime
  expired <-
    atomicModifyIORef' st.clsOpen $ \m ->
      let (due, keep) = M.partition (\oc -> oc.ocDeadline <= now) m
       in (keep, M.toList due)
  forM_ expired $ \(camId, oc) ->
    closeOne cfg st camId oc
      `catchClip` \e ->
        logError ("ClipRecorder: close failed for " <> oc.ocSlug <> ": " <> T.pack (show e))

-- | 'try' wrapper that rethrows async exceptions (pitfall #107) and
-- hands synchronous failures to the caller-supplied logger.
catchClip :: IO () -> (SomeException -> IO ()) -> IO ()
catchClip act onErr = do
  r <- try act
  case r of
    Right () -> pure ()
    Left e ->
      case fromException e of
        Just (SomeAsyncException _) -> throwIO e
        Nothing -> onErr e

-- | Upload init + fragments under the clip prefix and publish
-- 'ClipReady'. Clips with no init segment or no fragments are dropped
-- with a warning (unplayable — better absent than a dead row).
closeOne :: CaptureConfig -> ClipState -> CameraId -> OpenClip -> IO ()
closeOne cfg st camId oc = do
  now <- getCurrentTime
  tailFrags <- do
    mBuf <- M.lookup camId <$> readIORef st.clsBufs
    case mBuf of
      Nothing -> pure []
      Just bufTVar -> RB.window oc.ocLastSnap oc.ocDeadline <$> readTVarIO bufTVar
  let frags = oc.ocFrags <> Seq.fromList tailFrags
  case (oc.ocInit, Seq.null frags) of
    (Nothing, _) ->
      logWarn ("ClipRecorder: dropping clip for " <> oc.ocSlug <> " — no init segment buffered")
    (_, True) ->
      logWarn ("ClipRecorder: dropping clip for " <> oc.ocSlug <> " — no fragments buffered")
    (Just initBs, False) ->
      case (capS3 cfg, capBus cfg) of
        (Just ci, Just bus) -> do
          let prefix = clipPrefix oc.ocSlug oc.ocStartedAt
              opts = defaultPutObjectOptions {pooContentType = Just "video/mp4"}
          putObjectBytes ci (capBucket cfg) (clipInitKey prefix) initBs opts
          forM_ frags $ \e ->
            putObjectBytes ci (capBucket cfg) (clipFragKey prefix (reStart e)) (reBytes e) opts
          Bus.publishJson bus Subjects.events $
            ClipReady
              { crCamera = camId,
                crSlug = oc.ocSlug,
                crRuleId = Just oc.ocRuleId,
                crStartedAt = oc.ocStartedAt,
                crDurationSec = clipDurationSec oc.ocStartedAt (max oc.ocDeadline now),
                crObjectPrefix = prefix,
                crRetentionHours = oc.ocRetentionHours,
                crHost = capHostId cfg
              }
          logInfo
            ( "ClipRecorder: clip closed for "
                <> oc.ocSlug
                <> " ("
                <> T.pack (show (Seq.length frags))
                <> " fragments, prefix "
                <> prefix
                <> ")"
            )
        _ ->
          logWarn
            ( "ClipRecorder: S3 or NATS unconfigured; dropping clip for "
                <> oc.ocSlug
            )
