{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Alive-but-blind analysis-pair detection (pitfall #135).
--
-- An analysis pair can be running and publishing frames while its
-- rule evaluation emits nothing — the Sep 19 2026 snp-srv/nixos
-- incident: pairs restarted while the leader was down, then produced
-- zero rule events for ~2 days. The frame-source watchdog can't see
-- it: the pair's newest analyzed frame stays fresh, so neither the
-- dead-async nor the stale-frame checks fire.
--
-- The distinguishing signal is rule-activity silence /while tracks
-- are present/: a quiet camera legitimately emits no events, but
-- tracks recently seen with no event for hours means the eval
-- pipeline is wedged. 'blindVerdict' is pure (pitfall #14 extraction
-- pattern) — the IO glue lives in "Hnvr.Node.CaptureSupervisor"'s
-- watchdog.
module Hnvr.Core.AnalysisLiveness
  ( RuleActivity (..),
    BlindParams (..),
    defaultBlindParams,
    BlindVerdict (..),
    blindVerdict,
  )
where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (UTCTime, diffUTCTime)

-- | Per-camera rule-activity timestamps, recorded by the analysis
-- sink on every analyzed frame / emitted rule event. Both use the
-- frame's wall timestamp (see 'Hnvr.Core.Frame.frameTimestamp').
data RuleActivity = RuleActivity
  { -- | Newest frame that carried at least one confirmed track.
    raLastTrackSeen :: !UTCTime,
    -- | Newest rule event emitted by the pair.
    raLastEvent :: !UTCTime
  }
  deriving stock (Eq, Show)

-- | Tunables for 'blindVerdict', read once from the environment when
-- the watchdog starts (@HNVR_BLIND_TRACK_QUIET_SEC@ /
-- @HNVR_BLIND_EVENT_QUIET_SEC@).
data BlindParams = BlindParams
  { -- | No confirmed tracks for this long ⇒ the camera is quiet and
    -- absence of rule events is expected (never restart on that).
    bpTrackQuietSec :: !Double,
    -- | Tracks recently seen but no rule event for this long ⇒
    -- alive-but-blind (restart the pair).
    bpEventQuietSec :: !Double
  }
  deriving stock (Eq, Show)

defaultBlindParams :: BlindParams
defaultBlindParams =
  BlindParams
    { bpTrackQuietSec = 1800,
      bpEventQuietSec = 7200
    }

-- | Decision of one blind check.
data BlindVerdict
  = -- | No activity recorded yet (pair just started) — grace.
    BlindNoData
  | -- | No tracks recently: quiet camera, no events expected.
    BlindQuiet
  | -- | Events flowing within the window (or tracks just appeared).
    BlindAlive
  | -- | Tracks active but events silent past 'bpEventQuietSec' —
    -- restart the pair. Text = human reason for the log line.
    BlindWedged !Text
  deriving stock (Eq, Show)

-- | Pure blind-check decision. @now@ is the watchdog scan time;
-- @Nothing@ = no activity recorded for the camera yet.
blindVerdict :: BlindParams -> UTCTime -> Maybe RuleActivity -> BlindVerdict
blindVerdict params now mActivity = case mActivity of
  Nothing -> BlindNoData
  Just (RuleActivity lastTrack lastEvent)
    | age lastTrack > bpTrackQuietSec params -> BlindQuiet
    | age lastEvent <= bpEventQuietSec params -> BlindAlive
    | otherwise ->
        BlindWedged
          ( "tracks active but no rule event for "
              <> T.pack (show (round (age lastEvent) :: Int))
              <> "s"
          )
  where
    age t = realToFrac (diffUTCTime now t)
