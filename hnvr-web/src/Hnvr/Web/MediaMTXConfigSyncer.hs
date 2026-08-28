{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Leader-side MediaMTXConfigSyncer.
--
-- Listens on the Postgres @cameras_events@ channel (LISTEN/NOTIFY) and
-- regenerates @/run/hnvr/mediamtx.yml@ + pushes per-path config to
-- MediaMTX's REST API whenever a camera row changes. The YAML file is
-- the source of truth at mediamtx boot; the REST API provides live
-- reload without restart (so WebRTC sessions aren't dropped).
--
-- Why LISTEN/NOTIFY over polling: <1 s latency, no constant DB load,
-- scales as the camera count grows. Hasql 1.9.x has no Notification
-- module, so we open a dedicated @postgresql-simple@ connection here.
-- The trigger function is created idempotently at leader startup so
-- there's no separate migration to run.
--
-- Failure modes:
--   * Postgres unreachable at startup: log + bail (leader still serves
--     HTTP; ConfigSyncer retries on next leader restart).
--   * mediamtx REST API unreachable: file is still updated; live reload
--     happens on next successful REST push or mediamtx restart.
module Hnvr.Web.MediaMTXConfigSyncer
  ( startMediaMTXConfigSyncer,
  )
where

import Control.Concurrent.Async (async)
import Control.Exception (SomeException, bracket, catch)
import Control.Monad (forever, void, when)
import Data.Aeson (Value)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.Types as Aeson.Types
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe, maybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Database.PostgreSQL.Simple (Connection)
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.Notification as PG
import Generated.Types
import Hnvr.Core.AudioProbe (ProbedAudio (..))
import Hnvr.Core.CameraSnapshot (audioInputRateHz)
import Hnvr.Core.Logging (logError, logInfo)
import Hnvr.Core.MediaMtxLive
  ( AudioPresence (..),
    CameraPath (..),
    LiveAudio (..),
    pathConfigs,
    renderPathsYaml,
  )
import Hnvr.Web.AudioProbe (probeCameraAudio)
import IHP.Fetch (fetch)
import IHP.HaskellSupport ((|>))
import IHP.ModelSupport (ModelContext)
import IHP.QueryBuilder (orderByAsc, query)
import Network.HTTP.Client (Manager, RequestBody (..))
import qualified Network.HTTP.Client as HC
import qualified System.Directory as Dir
import qualified System.Environment as Env

-- | Where the leader writes the canonical mediamtx.yml. The mediamtx
-- service unit reads this on startup; the REST API provides live
-- reload between restarts.
defaultConfigPath :: FilePath
defaultConfigPath = "/run/hnvr/mediamtx.yml"

-- | mediamtx REST API base. Default port 9997 (configurable in the
-- NixOS module). Read from @HNVR_MEDIAMTX_API@ env at startup so
-- non-default deployments don't need a rebuild.
defaultMediaMtxApi :: Text
defaultMediaMtxApi = "http://127.0.0.1:9997"

-- | Spawns the ConfigSyncer in a background async. Idempotent — safe
-- to call once per leader process. The async lives for the lifetime of
-- the process; if the LISTEN connection dies, we'd need a reconnect
-- loop (TODO Slice 2b — for now we accept that a PG outage past leader
-- restart is the recovery path, matching EventWriter's behavior).
startMediaMTXConfigSyncer :: (?modelContext :: ModelContext) => IO ()
startMediaMTXConfigSyncer = do
  ensureTrigger
  _ <- async listenLoop
  logInfo "MediaMTXConfigSyncer: started, listening on cameras_events"

-- | Idempotently install the @cameras_events@ NOTIFY trigger. Safe to
-- call on every leader boot.
--
-- Bypasses Hasql (IHP's @unsafeSqlExec @ is a no-row decoder alias and
-- fails DDL with @UnexpectedResultStatementError "Empty bytes"@ on
-- IHP v1.6.0 — see project pitfall #42). Uses postgresql-simple on a
-- one-shot connection instead; the same lib already powers our LISTEN
-- loop below.
ensureTrigger :: IO ()
ensureTrigger = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  bracket (PG.connectPostgreSQL dbUrl) PG.close $ \conn ->
    mapM_ (PG.execute_ conn) [triggerFuncSql, dropTriggerSql, createTriggerSql]
  where
    triggerFuncSql =
      "CREATE OR REPLACE FUNCTION hnvr_notify_cameras_events()\
      \ RETURNS trigger AS $$\
      \ BEGIN\
      \   PERFORM pg_notify('cameras_events', json_build_object(\
      \     'op', TG_OP,\
      \     'slug', COALESCE(NEW.slug, OLD.slug)\
      \   )::text);\
      \   RETURN COALESCE(NEW, OLD);\
      \ END;\
      \ $$ LANGUAGE plpgsql"
    dropTriggerSql = "DROP TRIGGER IF EXISTS cameras_events_notify ON cameras"
    createTriggerSql =
      "CREATE TRIGGER cameras_events_notify\
      \ AFTER INSERT OR UPDATE OR DELETE ON cameras\
      \ FOR EACH ROW EXECUTE FUNCTION hnvr_notify_cameras_events()"

-- | Top-level LISTEN loop. Owns its own postgresql-simple connection
-- (separate from IHP's Hasql pool — LISTEN must hold a connection in
-- idle state to receive notifies). Re-renders + REST-pushes on every
-- notification, with a one-shot sync at startup so mediamtx has the
-- current config even if nothing has changed since last leader boot.
listenLoop :: (?modelContext :: ModelContext) => IO ()
listenLoop = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  mgr <- HC.newManager HC.defaultManagerSettings
  apiBase <- maybe defaultMediaMtxApi T.pack <$> Env.lookupEnv "HNVR_MEDIAMTX_API"
  cfgPath <- fromMaybe defaultConfigPath <$> Env.lookupEnv "HNVR_MEDIAMTX_CONFIG_PATH"
  relayBase <- maybe defaultRelayRtsp T.pack <$> Env.lookupEnv "HNVR_MEDIAMTX_RTSP_BASE"
  probeCache <- newIORef Map.empty
  -- Initial sync — covers the leader-restart case where cameras
  -- changed while the leader was down. Caught separately from the
  -- LISTEN loop: a failure here (e.g. the mediamtx config dir not
  -- writable under ProtectSystem=strict) used to kill the async
  -- before LISTEN started, silently — no file, no REST push, no
  -- re-sync on later camera events.
  syncOnce mgr apiBase cfgPath relayBase probeCache
    `catch` \(e :: SomeException) ->
      logError ("MediaMTXConfigSyncer: initial sync failed: " <> T.pack (show e))
  listenWith dbUrl (const $ syncOnce mgr apiBase cfgPath relayBase probeCache)
    `catch` \(e :: SomeException) ->
      logError ("MediaMTXConfigSyncer: LISTEN loop died: " <> T.pack (show e))

-- | Base URL of THIS host's mediamtx RTSP server — both the input the
-- @runOnDemand@ republisher pulls and the endpoint it publishes the
-- slug-live path to. Override when mediamtx is not co-located
-- (same rule as @HNVR_MEDIAMTX_API@).
defaultRelayRtsp :: Text
defaultRelayRtsp = "rtsp://127.0.0.1:8554"

-- | Default DB URL matches IHP's. Real deployments set DATABASE_URL.
defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"

-- | Connect, LISTEN, loop. Reconnect logic is deferred (Slice 2b).
listenWith :: BS.ByteString -> (PG.Notification -> IO ()) -> IO ()
listenWith dbUrl onNotif = do
  conn <- PG.connectPostgreSQL dbUrl
  _ <- PG.execute_ conn "LISTEN cameras_events"
  logInfo "MediaMTXConfigSyncer: LISTEN cameras_events"
  forever $ do
    n <- PG.getNotification conn
    onNotif n

-- | Render the current cameras table to mediamtx.yml, write it
-- atomically, and push per-path updates to the mediamtx REST API.
-- Cameras whose audio columns are unknown get a live probe
-- ("Hnvr.Web.AudioProbe") before rendering, cached per slug.
syncOnce :: (?modelContext :: ModelContext) => Manager -> Text -> FilePath -> Text -> IORef (Map.Map Text LiveAudio) -> IO ()
syncOnce mgr apiBase cfgPath relayBase probeCache = do
  cameras <-
    query @Camera
      |> orderByAsc #slug
      |> fetch
  paths <- mapM (cameraPath relayBase probeCache) cameras
  writeAtomic cfgPath (renderPathsYaml relayBase paths)
  pushPaths mgr apiBase (pathConfigs relayBase paths)
    `catch` \(e :: SomeException) ->
      logError ("MediaMTXConfigSyncer: REST push failed (file still written): " <> T.pack (show e))

cameraPath :: Text -> IORef (Map.Map Text LiveAudio) -> Camera -> IO CameraPath
cameraPath relayBase probeCache cam = do
  la <- resolveLiveAudio relayBase probeCache cam
  pure
    CameraPath
      { cpSlug = cam.slug,
        cpSource = cam.rtspUrl,
        cpTransport = cam.rtspTransport,
        cpEnabled = cam.enabled,
        cpLiveAudio = la
      }

resolveLiveAudio :: Text -> IORef (Map.Map Text LiveAudio) -> Camera -> IO LiveAudio
resolveLiveAudio relayBase probeCache cam =
  case audioInputRateHz cam.audioEncoding cam.audioSampleRateKhz of
    Just hz -> pure (LiveAudio (Just hz) AudioYes)
    Nothing -> case cam.audioEncoding of
      Just enc | enc `notElem` ["G711", "G726"] -> pure (LiveAudio Nothing AudioYes)
      _ -> probe
  where
    slug = cam.slug
    probe = do
      cached <- Map.lookup slug <$> readIORef probeCache
      case cached of
        Just la -> pure la
        Nothing -> do
          mpa <- probeCameraAudio (relayBase <> "/" <> slug)
          let la = case mpa of
                Nothing -> LiveAudio Nothing AudioUnknown
                Just pa -> LiveAudio (paAsetrateHz pa) AudioYes
          atomicModifyIORef' probeCache (\m -> (Map.insert slug la m, ()))
          logInfo ("MediaMTXConfigSyncer: probed live audio for " <> slug <> ": " <> T.pack (show la))
          pure la

-- | Atomic file write: write to @<path>.tmp@ then rename. Avoids mediamtx
-- reading a partially-written file on SIGHUP/restart.
writeAtomic :: FilePath -> Text -> IO ()
writeAtomic path body = do
  let tmp = path <> ".tmp"
  Dir.createDirectoryIfMissing True (dirOf path)
  TIO.writeFile tmp body
  Dir.renameFile tmp path
  where
    dirOf = reverse . dropWhile (/= '/') . reverse

-- | Compute the per-path add/patch/delete plan and execute it.
-- mediamtx v1.16+ split the upsert-style @PUT /v2/config/paths/<id>@
-- into three operations:
--   * @POST   /v3/config/paths/add/<name>@    — create; 400 if exists
--   * @PATCH  /v3/config/paths/patch/<name>@  — patch;   404 if not
--   * @DELETE /v3/config/paths/delete/<name>@ — delete; 404 if not
-- We list remote first to decide add-vs-patch per desired path, and
-- to compute the orphan set for deletion (both the ingestion path
-- and its -live companion are desired entries — see
-- "Hnvr.Core.MediaMtxLive"). REST methods matter (POST add vs PATCH
-- patch vs DELETE delete) — earlier impl used PUT for everything
-- which 404'd on v1.20.0 (Taiga #467).
pushPaths :: Manager -> Text -> [(Text, Value)] -> IO ()
pushPaths mgr apiBase desiredCfgs = do
  existing <- listRemotePaths mgr apiBase
  let desired = Map.fromList desiredCfgs
      toAdd = [(slug, cfg) | (slug, cfg) <- Map.toList desired, slug `notElem` existing]
      toPatch = [(slug, cfg) | (slug, cfg) <- Map.toList desired, slug `elem` existing]
      toDelete = filter (`notElem` Map.keys desired) existing
  mapM_ (uncurry (addPath mgr apiBase)) toAdd
  mapM_ (uncurry (patchPath mgr apiBase)) toPatch
  mapM_ (deletePath mgr apiBase) toDelete
  when (not (null toAdd) || not (null toPatch) || not (null toDelete)) $
    logInfo
      ( "MediaMTXConfigSyncer: added "
          <> T.pack (show (length toAdd))
          <> ", patched "
          <> T.pack (show (length toPatch))
          <> ", deleted "
          <> T.pack (show (length toDelete))
      )

-- | @GET /v3/config/paths/list@ → list of path names. mediamtx v1.20
-- returns @{itemCount, pageCount, items: [{name, ...}]}; we only
-- need the names for set-difference logic. Decoded via Aeson's
-- parser monad to keep the field shape explicit.
listRemotePaths :: Manager -> Text -> IO [Text]
listRemotePaths mgr apiBase = do
  req <- HC.parseRequest (T.unpack apiBase <> "/v3/config/paths/list")
  resp <- HC.httpLbs req mgr
  let mb = Aeson.decode (HC.responseBody resp) >>= Aeson.Types.parseMaybe parseList
  pure (fromMaybe [] mb)
  where
    parseList = Aeson.withObject "PathList" $ \o -> do
      items <- o Aeson..: "items"
      mapM (Aeson.withObject "PathItem" (Aeson..: "name")) items

addPath :: Manager -> Text -> Text -> Value -> IO ()
addPath mgr apiBase slug cfg = do
  initReq <- HC.parseRequest (T.unpack apiBase <> "/v3/config/paths/add/" <> T.unpack slug)
  let req =
        initReq
          { HC.method = "POST",
            HC.requestBody = RequestBodyLBS (Aeson.encode cfg),
            HC.requestHeaders = [("Content-Type", "application/json")]
          }
  _ <- HC.httpLbs req mgr
  pure ()

patchPath :: Manager -> Text -> Text -> Value -> IO ()
patchPath mgr apiBase slug cfg = do
  initReq <- HC.parseRequest (T.unpack apiBase <> "/v3/config/paths/patch/" <> T.unpack slug)
  let req =
        initReq
          { HC.method = "PATCH",
            HC.requestBody = RequestBodyLBS (Aeson.encode cfg),
            HC.requestHeaders = [("Content-Type", "application/json")]
          }
  _ <- HC.httpLbs req mgr
  pure ()

deletePath :: Manager -> Text -> Text -> IO ()
deletePath mgr apiBase slug = do
  initReq <- HC.parseRequest (T.unpack apiBase <> "/v3/config/paths/delete/" <> T.unpack slug)
  let req = initReq {HC.method = "DELETE"}
  _ <- HC.httpLbs req mgr
  pure ()
