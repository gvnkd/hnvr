{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | ONVIF PTZ driver: a resolved camera endpoint + the 'Hnvr.Ptz.Driver'
-- surface as plain IO functions over it.
--
-- Resolution ('resolveOnvifPtz') discovers the PTZ service XAddr from
-- the device service (@GetCapabilities@) — the path AND port vary per
-- firmware (Hik-OEM: @:80/onvif/ptz@, XM stock: @:8899/onvif/ptz_service@),
-- so hardcoding is not an option. A camera that doesn't advertise PTZ
-- resolves to 'Left' with a human-readable reason (the supervisor logs
-- it and runs no controller for that camera).
module Hnvr.Ptz.Onvif
  ( OnvifPtz (..),
    resolveOnvifPtz,
    continuousMove,
    stop,
    absoluteMove,
    gotoPreset,
    setPreset,
    removePreset,
    getPresets,
    getStatus,
  )
where

import Data.Text (Text)
import qualified Data.Text as T
import Hnvr.Core.Ptz
import Hnvr.Onvif.Client
import qualified Network.HTTP.Client as HC

-- | Everything needed to drive one camera's PTZ service.
data OnvifPtz = OnvifPtz
  { opMgr :: !HC.Manager,
    opCreds :: !OnvifCreds,
    -- | PTZ service XAddr (e.g. @http://192.168.0.196:80/onvif/ptz@).
    opXaddr :: !Text,
    -- | Media profile token the ops address
    -- (@cameras.ptz_profile_token@).
    opProfileToken :: !Text
  }

-- | Discover + build the endpoint. 'Left' explains why the camera is
-- not PTZ-drivable (no PTZ service advertised, transport error, ...).
resolveOnvifPtz ::
  HC.Manager -> OnvifCreds -> Text -> Int -> Text -> IO (Either Text OnvifPtz)
resolveOnvifPtz mgr creds host port profileToken = do
  e <- discoverPtzXAddr mgr creds host port
  pure $ case e of
    Left err -> Left ("ptz discovery failed: " <> errText err)
    Right Nothing -> Left "camera advertises no PTZ service"
    Right (Just xaddr) -> Right (OnvifPtz mgr creds xaddr profileToken)

continuousMove :: OnvifPtz -> Velocity -> Maybe Int -> IO (Either OnvifError ())
continuousMove p = ptzContinuousMove (opMgr p) (opCreds p) (opXaddr p) (opProfileToken p)

stop :: OnvifPtz -> StopAxes -> IO (Either OnvifError ())
stop p = ptzStop (opMgr p) (opCreds p) (opXaddr p) (opProfileToken p)

absoluteMove :: OnvifPtz -> PtzPosition -> IO (Either OnvifError ())
absoluteMove p = ptzAbsoluteMove (opMgr p) (opCreds p) (opXaddr p) (opProfileToken p)

gotoPreset :: OnvifPtz -> PresetToken -> IO (Either OnvifError ())
gotoPreset p = ptzGotoPreset (opMgr p) (opCreds p) (opXaddr p) (opProfileToken p)

setPreset :: OnvifPtz -> PresetName -> IO (Either OnvifError PresetToken)
setPreset p = ptzSetPreset (opMgr p) (opCreds p) (opXaddr p) (opProfileToken p)

removePreset :: OnvifPtz -> PresetToken -> IO (Either OnvifError ())
removePreset p = ptzRemovePreset (opMgr p) (opCreds p) (opXaddr p) (opProfileToken p)

getPresets :: OnvifPtz -> IO (Either OnvifError [OnvifPreset])
getPresets p = ptzGetPresets (opMgr p) (opCreds p) (opXaddr p) (opProfileToken p)

getStatus :: OnvifPtz -> IO (Either OnvifError (Maybe PtzPosition))
getStatus p = ptzGetStatus (opMgr p) (opCreds p) (opXaddr p) (opProfileToken p)

errText :: OnvifError -> Text
errText (OnvifTransportError t) = "transport: " <> t
errText (OnvifHttpError st t) = "HTTP " <> tshow st <> ": " <> t
errText (OnvifFault t) = "SOAP fault: " <> t
errText (OnvifParseError t) = "parse: " <> t

tshow :: (Show a) => a -> Text
tshow = T.pack . show
