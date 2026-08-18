{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | ONVIF config sync shared logic: projects a Camera row into the
-- sparse 'DesiredVideo'/'DesiredAudio' shapes, pushes desired encoder
-- settings to the camera, and reads back observed settings for drift
-- detection.
--
-- Push flow per camera:
--
--   1. discoverMediaXAddr (device service → media XAddr; path/port vary
--      per firmware so discovery is mandatory)
--   2. Get*Configurations + Get*ConfigurationOptions
--   3. 'clampVideo'/'clampAudio' snap desired values into what the
--      camera offers
--   4. Set*EncoderConfiguration only for configs whose clamped value
--      differs from the observed one (idempotent — no churn when the
--      camera already matches)
--
-- Used by 'Web.Controller.Cameras' (push on "Save Changes") and
-- 'Hnvr.Web.OnvifSyncer' (periodic drift check).
module Hnvr.Web.OnvifSync
  ( OnvifTarget (..),
    targetForCamera,
    desiredMainVideo,
    desiredSubVideo,
    desiredAudioCfg,
    pushCameraConfig,
    checkCameraDrift,
    probePtz,
    FormOptions (..),
    fetchFormOptions,
  )
where

import Data.Either (fromRight)
import Data.Text (Text)
import qualified Data.Text as T
import Generated.Types
import Hnvr.Core.Dvrip (SimplifyEncode (..), applyDesiredVideo, dvripVideoDrift)
import Hnvr.Core.Onvif
import Hnvr.Core.Ptz (PtzPosition)
import Hnvr.Dvrip.Client (DvripCreds (..), DvripError (..), dvripGetEncode, dvripSetEncode)
import Hnvr.Onvif.Client
import qualified Network.HTTP.Client as HC
import Web.Controller.Support.Crypto (decryptPassword)

-- | Management protocol for encoder config sync: ONVIF (default) or
-- DVRIP (XM "Sofia" native, for cameras whose ONVIF layer is
-- decorative — e.g. low_ent/cam-198).
data MgmtProto = ProtoOnvif | ProtoDvrip
  deriving stock (Eq, Show)

-- | Everything needed to talk to one camera's management interface.
-- For 'ProtoDvrip', 'otPort' is the DVRIP port (34567).
data OnvifTarget = OnvifTarget
  { otProto :: !MgmtProto,
    otHost :: !Text,
    otPort :: !Int,
    otCreds :: !OnvifCreds
  }
  deriving stock (Eq, Show)

-- | Resolve the management endpoint for a camera. 'Left' explains why
-- the camera is not manageable (no port, no host, no credentials).
-- The host falls back to the RTSP URL's authority when the cameras
-- @host@ column is unset/empty (the common case — URLs carry it).
targetForCamera :: Camera -> IO (Either Text OnvifTarget)
targetForCamera cam = case (cam.onvifPort, mHost) of
  (Nothing, _) -> pure (Left "unmanaged (onvif_port not set)")
  (_, Nothing) -> pure (Left "no host configured (host column empty, no RTSP URL host)")
  (Just port', Just host') -> do
    mPw <- decryptPassword cam.passwordEnc cam.passwordNonce
    case (nonEmpty cam.username, mPw) of
      (Just u, Just pw) -> pure (Right (OnvifTarget proto host' port' (OnvifCreds u pw)))
      _ -> pure (Left "missing credentials (username/password)")
  where
    proto = if cam.mgmtProto == "dvrip" then ProtoDvrip else ProtoOnvif
    mHost = case cam.host of
      Just h | not (T.null h) -> Just h
      _ -> hostFromRtspUrl cam.rtspUrl
    nonEmpty (Just t) | not (T.null t) = Just t
    nonEmpty _ = Nothing

-- | Sparse desired video config for the main stream (Maybe fields come
-- from the flat cameras columns; NULL = unmanaged).
desiredMainVideo :: Camera -> DesiredVideo
desiredMainVideo cam =
  DesiredVideo
    (parseVideoEncoding <$> cam.mainVideoEncoding)
    cam.mainVideoWidth
    cam.mainVideoHeight
    cam.mainVideoFps
    cam.mainVideoBitrateKbps
    cam.mainVideoGovLength

-- | Sparse desired video config for the sub-stream.
desiredSubVideo :: Camera -> DesiredVideo
desiredSubVideo cam =
  DesiredVideo
    (parseVideoEncoding <$> cam.subVideoEncoding)
    cam.subVideoWidth
    cam.subVideoHeight
    cam.subVideoFps
    cam.subVideoBitrateKbps
    cam.subVideoGovLength

-- | Sparse desired audio config.
desiredAudioCfg :: Camera -> DesiredAudio
desiredAudioCfg cam =
  DesiredAudio
    (parseAudioEncoding <$> cam.audioEncoding)
    cam.audioBitrateKbps
    cam.audioSampleRateKhz

-- | Push desired encoder settings. Returns a human-readable summary of
-- what was sent (e.g. "main video, audio") or an error. Branches on the
-- camera's management protocol.
pushCameraConfig :: HC.Manager -> OnvifTarget -> Camera -> IO (Either Text Text)
pushCameraConfig mgr target cam = case target.otProto of
  ProtoDvrip -> pushDvrip target cam
  ProtoOnvif -> pushOnvif mgr target cam

-- | DVRIP push: get Simplify.Encode, apply desired main/sub (sparse),
-- set back only if changed. Audio codec is not configurable on XM —
-- reported as unmanaged.
pushDvrip :: OnvifTarget -> Camera -> IO (Either Text Text)
pushDvrip target cam = do
  e <- dvripGetEncode creds target.otHost target.otPort
  case e of
    Left err -> pure (Left (dErrText err))
    Right se -> do
      let se' =
            SimplifyEncode
              { seMain = applyDesiredVideo (desiredMainVideo cam) (seMain se),
                seExtra = applyDesiredVideo (desiredSubVideo cam) (seExtra se)
              }
      if se' == se
        then pure (Right "already in sync (dvrip)")
        else do
          r <- dvripSetEncode creds target.otHost target.otPort se'
          pure $ case r of
            Left err -> Left (dErrText err)
            Right () -> Right "pushed: main+sub video (dvrip)"
  where
    creds = DvripCreds target.otCreds.ocUser target.otCreds.ocPass

-- | ONVIF push. Sections whose clamped value already equals the
-- observed value are skipped.
--
-- Options are fetched PER CONFIG TOKEN: main and sub offer different
-- resolution/fps sets on real firmware, and clamping against the merged
-- untokened view lets cross-stream values through (XM rejects those
-- with ter:ConfigModify). A failed per-token query falls back to the
-- untokened options.
pushOnvif :: HC.Manager -> OnvifTarget -> Camera -> IO (Either Text Text)
pushOnvif mgr target cam = do
  eMedia <- discoverMediaXAddr mgr target.otCreds target.otHost target.otPort
  case eMedia of
    Left e -> pure (Left (errText e))
    Right media -> do
      eVideos <- getVideoConfigs mgr target.otCreds media
      eAudios <- getAudioConfigs mgr target.otCreds media
      case (eVideos, eAudios) of
        (Right videos, Right audios) -> do
          let (mMain, mSub) = pickMainSub videos
          pushed <-
            concat
              <$> sequence
                [ pushVideo media "main video" (desiredMainVideo cam) mMain,
                  pushVideo media "sub video" (desiredSubVideo cam) mSub,
                  pushAudios media (desiredAudioCfg cam) audios
                ]
          pure $
            Right
              ( if null pushed
                  then "already in sync"
                  else "pushed: " <> T.intercalate ", " pushed
              )
        (Left e, _) -> pure (Left (errText e))
        (_, Left e) -> pure (Left (errText e))
  where
    creds = target.otCreds
    pushVideo media label desired = maybe (pure []) $ \cur -> do
      vopts <- videoOptsFor media (Just (vcToken cur))
      let clamped = clampVideo vopts cur desired
      if clamped == cur
        then pure []
        else do
          res <- setVideoConfig mgr creds media clamped
          pure (either (\e -> [label <> " FAILED (" <> errText e <> ")"]) (const [label]) res)
    pushAudios media desired audios =
      concat
        <$> mapM
          ( \cur -> do
              aopts <- audioOptsFor media (Just (acToken cur))
              let clamped = clampAudio aopts cur desired
              if clamped == cur
                then pure []
                else do
                  res <- setAudioConfig mgr creds media clamped
                  pure (either (\e -> ["audio FAILED (" <> errText e <> ")"]) (const ["audio"]) res)
          )
          audios
    -- Per-token options, falling back to the untokened (merged) query,
    -- then to unconstrained.
    videoOptsFor media mToken = do
      e <- getVideoOptions mgr creds media mToken
      case e of
        Right o -> pure o
        Left _ -> fromRight (VideoOptions [] [] Nothing Nothing Nothing) <$> getVideoOptions mgr creds media Nothing
    audioOptsFor media mToken = do
      e <- getAudioOptions mgr creds media mToken
      case e of
        Right o -> pure o
        Left _ -> fromRight (AudioOptions [] [] []) <$> getAudioOptions mgr creds media Nothing

-- | Capabilities for the Edit form dropdowns. 'Nothing' per section
-- means the camera didn't answer (form falls back to free-text inputs).
data FormOptions = FormOptions
  { foMain :: !(Maybe VideoOptions),
    foSub :: !(Maybe VideoOptions),
    foAudio :: !(Maybe AudioOptions)
  }
  deriving stock (Eq, Show)

fetchFormOptions :: HC.Manager -> OnvifTarget -> IO FormOptions
fetchFormOptions _ target | target.otProto == ProtoDvrip = pure (FormOptions Nothing Nothing Nothing)
fetchFormOptions mgr target = do
  eMedia <- discoverMediaXAddr mgr target.otCreds target.otHost target.otPort
  case eMedia of
    Left _ -> pure (FormOptions Nothing Nothing Nothing)
    Right media -> do
      eVideos <- getVideoConfigs mgr target.otCreds media
      eAudios <- getAudioConfigs mgr target.otCreds media
      case (eVideos, eAudios) of
        (Right videos, Right audios) -> do
          let (mMain, mSub) = pickMainSub videos
              vOptsFor = fmap eitherToMaybe . getVideoOptions mgr target.otCreds media . fmap vcToken
              aOptsFor = fmap eitherToMaybe . getAudioOptions mgr target.otCreds media . fmap acToken
          mainOpts <- vOptsFor mMain
          subOpts <- vOptsFor mSub
          audioOpts <- aOptsFor (headMay audios)
          pure (FormOptions mainOpts subOpts audioOpts)
        _ -> pure (FormOptions Nothing Nothing Nothing)
  where
    eitherToMaybe = either (const Nothing) Just
    headMay [] = Nothing
    headMay (x : _) = Just x

-- | Read back the camera's current encoder settings and diff against
-- desired. 'Left' on any transport/parse failure (camera offline,
-- management protocol absent, ...).
checkCameraDrift :: HC.Manager -> OnvifTarget -> Camera -> IO (Either Text [DriftItem])
checkCameraDrift mgr target cam = case target.otProto of
  ProtoDvrip -> do
    e <- dvripGetEncode creds' target.otHost target.otPort
    pure $ case e of
      Left err -> Left (dErrText err)
      Right se ->
        Right
          ( dvripVideoDrift "main" (desiredMainVideo cam) (seMain se)
              <> dvripVideoDrift "sub" (desiredSubVideo cam) (seExtra se)
          )
  ProtoOnvif -> do
    eMedia <- discoverMediaXAddr mgr target.otCreds target.otHost target.otPort
    case eMedia of
      Left e -> pure (Left (errText e))
      Right media -> do
        eVideos <- getVideoConfigs mgr target.otCreds media
        eAudios <- getAudioConfigs mgr target.otCreds media
        case (eVideos, eAudios) of
          (Right videos, Right audios) -> do
            let (mMain, mSub) = pickMainSub videos
                driftItems =
                  maybe [] (labelDrift "main" . videoDrift (desiredMainVideo cam)) mMain
                    <> maybe [] (labelDrift "sub" . videoDrift (desiredSubVideo cam)) mSub
                    <> concatMap (labelDrift "audio" . audioDrift (desiredAudioCfg cam)) audios
            pure (Right driftItems)
          (Left e, _) -> pure (Left (errText e))
          (_, Left e) -> pure (Left (errText e))
  where
    creds' = DvripCreds target.otCreds.ocUser target.otCreds.ocPass

labelDrift :: Text -> [DriftItem] -> [DriftItem]
labelDrift prefix = map (\d -> d {diConfig = prefix <> ":" <> diConfig d})

-- | PTZ probe (Phase 5): discover the PTZ service XAddr, resolve the
-- first media profile token, and read the current position. 'Right'
-- carries @(profileToken, Maybe position)@ — 'Nothing' position means
-- the camera reports a nil PTZStatus (no PTZ hardware; the Hik-OEM
-- turrets accept all PTZ ops as no-ops, which only the nil status
-- reveals).
probePtz :: HC.Manager -> OnvifTarget -> IO (Either Text (Text, Maybe PtzPosition))
probePtz _ target | target.otProto == ProtoDvrip = pure (Left "ptz requires mgmt_proto=onvif")
probePtz mgr target = do
  e <- discoverPtzXAddr mgr target.otCreds target.otHost target.otPort
  case e of
    Left err -> pure (Left (errText err))
    Right Nothing -> pure (Left "camera advertises no PTZ service (fixed camera)")
    Right (Just ptzXaddr) -> do
      eMedia <- discoverMediaXAddr mgr target.otCreds target.otHost target.otPort
      case eMedia of
        Left err -> pure (Left (errText err))
        Right media -> do
          eToks <- getProfileTokens mgr target.otCreds media
          case eToks of
            Left err -> pure (Left (errText err))
            Right [] -> pure (Left "camera reports no media profiles")
            Right ((tok, _) : _) -> do
              ePos <- ptzGetStatus mgr target.otCreds ptzXaddr tok
              pure (Right (tok, fromRight Nothing ePos))

errText :: OnvifError -> Text
errText (OnvifTransportError t) = "transport: " <> t
errText (OnvifHttpError st t) = "HTTP " <> T.pack (show st) <> ": " <> t
errText (OnvifFault t) = "SOAP fault: " <> t
errText (OnvifParseError t) = "parse: " <> t

dErrText :: DvripError -> Text
dErrText (DvripTransport t) = "dvrip transport: " <> t
dErrText (DvripAuth r) = "dvrip auth failed, Ret=" <> T.pack (show r)
dErrText (DvripCamera r t) = "dvrip camera error, Ret=" <> T.pack (show r) <> ": " <> t
dErrText (DvripParse t) = "dvrip parse: " <> t
