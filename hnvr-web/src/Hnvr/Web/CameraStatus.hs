{-# LANGUAGE OverloadedRecordDot #-}

-- | Resolve a camera's display status from the hosts table.
--
-- Thin projection layer between IHP records and the pure, cabal-tested
-- 'Hnvr.Core.CameraStatus.resolveCameraStatus': finds the camera's
-- assigned host row, checks heartbeat freshness (15 s window, same as
-- the AssignmentCoordinator), and digs the camera's worker state out
-- of @hosts.health_json@ (written by the HealthCache on every
-- @hnvr.health.<host>@ heartbeat).
module Hnvr.Web.CameraStatus
  ( cameraStatusFor,
    hostDisplayLive,
  )
where

import Data.List (find)
import Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime)
import Generated.Types
import Hnvr.Core.CameraStatus
  ( CameraHealth (..),
    CameraStatus,
    HostView (..),
    cameraHealthFromPayload,
    resolveCameraStatus,
  )
import IHP.HaskellSupport (get)
import IHP.ModelSupport (Id' (..))

-- | Heartbeat staleness window (seconds) — mirrors
-- @AssignmentCoordinator@'s 15-second host-down timeout.
freshWindowSeconds :: NominalDiffTime
freshWindowSeconds = 15

-- | Display liveness for the /Hosts page + dashboard host panel: a
-- host whose last heartbeat is older than 5 minutes renders as
-- disconnected (LED off). Deliberately longer than the 15 s assignment
-- window — a few missed heartbeats shouldn't flap the UI.
hostDisplayLive :: UTCTime -> Maybe UTCTime -> Bool
hostDisplayLive now = maybe False (\t -> diffUTCTime now t < 300)

cameraStatusFor :: [Host] -> UTCTime -> Camera -> CameraStatus
cameraStatusFor hosts now cam =
  resolveCameraStatus cam.enabled hostView
  where
    hostView = case cam.assignedHost of
      Nothing -> Nothing
      Just ah -> Just (hostViewFor ah)
    hostViewFor ah =
      case find (\h -> hostIdText h == ah) hosts of
        -- Assigned host has no row (never reported) — treat as down.
        Nothing -> HostView {hvHeartbeatFresh = False, hvCameraState = Nothing}
        Just h ->
          HostView
            { hvHeartbeatFresh =
                maybe False (\t -> diffUTCTime now t < freshWindowSeconds) h.lastHealthAt,
              hvCameraState =
                chState
                  <$> find (\ch -> ch.chSlug == cam.slug) (maybe [] cameraHealthFromPayload h.healthJson)
            }
    hostIdText h = case get #id h of Id t -> t
