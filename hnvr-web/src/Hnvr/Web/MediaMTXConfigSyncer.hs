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
import Data.Aeson (Value (..), object, (.=))
import qualified Data.Aeson as Aeson
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe, maybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Database.PostgreSQL.Simple (Connection)
import qualified Database.PostgreSQL.Simple as PG
import qualified Database.PostgreSQL.Simple.Notification as PG
import Generated.Types
import Hnvr.Core.Logging (logError, logInfo)
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
  -- Initial sync — covers the leader-restart case where cameras
  -- changed while the leader was down.
  syncOnce mgr apiBase cfgPath
  listenWith dbUrl (const $ syncOnce mgr apiBase cfgPath)
    `catch` \(e :: SomeException) ->
      logError ("MediaMTXConfigSyncer: LISTEN loop died: " <> T.pack (show e))

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
syncOnce :: (?modelContext :: ModelContext) => Manager -> Text -> FilePath -> IO ()
syncOnce mgr apiBase cfgPath = do
  cameras <-
    query @Camera
      |> orderByAsc #slug
      |> fetch
  let yaml = renderMediaMtxYaml cameras
  writeAtomic cfgPath yaml
  pushPaths mgr apiBase cameras
    `catch` \(e :: SomeException) ->
      logError ("MediaMTXConfigSyncer: REST push failed (file still written): " <> T.pack (show e))

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

-- | Render a minimal mediamtx.yml from the cameras table. Each enabled
-- camera becomes a path keyed by its slug, with @sourceOnDemand: yes@
-- so mediamtx only pulls RTSP when a viewer is watching.
renderMediaMtxYaml :: [Camera] -> Text
renderMediaMtxYaml cameras =
  T.unlines $
    [ "# Auto-generated by HNVR MediaMTXConfigSyncer. Do not edit.",
      "api: yes",
      "apiAddress: :9997",
      "webrtc: yes",
      "webrtcAddress: :8889",
      "webrtcEncryption: no",
      "webrtcAllowOrigin: '*'",
      "paths:"
    ]
      <> concatMap pathFor cameras
  where
    pathFor cam =
      let slug = cam.slug
          src = cam.rtspUrl
       in if cam.enabled
            then
              [ "  " <> slug <> ":",
                "    source: " <> src,
                "    sourceProtocol: tcp",
                "    sourceOnDemand: yes"
              ]
            else mempty

-- | Compute the per-path PUT/DELETE plan and execute it.
-- mediamtx's @PUT /v2/config/paths/<id>@ is upsert semantics: creates
-- the path if absent, replaces it if present. We PUT every currently
-- enabled camera (cheap), and DELETE any path that exists in mediamtx
-- but not in our camera list. The set of "currently in mediamtx" is
-- queried live each sync via @GET /v2/config/paths@.
pushPaths :: Manager -> Text -> [Camera] -> IO ()
pushPaths mgr apiBase cameras = do
  existing <- listRemotePaths mgr apiBase
  let desired = Map.fromList [(cam.slug, pathConfig cam) | cam <- cameras, cam.enabled]
      toPut = Map.toList desired
      toDelete = filter (`notElem` Map.keys desired) existing
  mapM_ (uncurry (putPath mgr apiBase)) toPut
  mapM_ (deletePath mgr apiBase) toDelete
  when (not (null toPut) || not (null toDelete)) $
    logInfo
      ( "MediaMTXConfigSyncer: pushed "
          <> T.pack (show (length toPut))
          <> " paths, deleted "
          <> T.pack (show (length toDelete))
      )

-- | @GET /v2/config/paths@ → list of path IDs. mediamtx returns a JSON
-- object whose top-level keys are path names.
listRemotePaths :: Manager -> Text -> IO [Text]
listRemotePaths mgr apiBase = do
  req <- HC.parseRequest (T.unpack apiBase <> "/v2/config/paths")
  resp <- HC.httpLbs req mgr
  case Aeson.decode (HC.responseBody resp) :: Maybe (Map.Map Text Value) of
    Just m -> pure (Map.keys m)
    Nothing -> pure []

-- | Per-path source config payload. Matches @renderMediaMtxYaml@.
pathConfig :: Camera -> Value
pathConfig cam =
  object
    [ "source" .= cam.rtspUrl,
      "sourceProtocol" .= ("tcp" :: Text),
      "sourceOnDemand" .= True
    ]

putPath :: Manager -> Text -> Text -> Value -> IO ()
putPath mgr apiBase slug cfg = do
  initReq <- HC.parseRequest (T.unpack apiBase <> "/v2/config/paths/" <> T.unpack slug)
  let req =
        initReq
          { HC.method = "PUT",
            HC.requestBody = RequestBodyLBS (Aeson.encode cfg),
            HC.requestHeaders = [("Content-Type", "application/json")]
          }
  _ <- HC.httpLbs req mgr
  pure ()

deletePath :: Manager -> Text -> Text -> IO ()
deletePath mgr apiBase slug = do
  initReq <- HC.parseRequest (T.unpack apiBase <> "/v2/config/paths/" <> T.unpack slug)
  let req = initReq {HC.method = "DELETE"}
  _ <- HC.httpLbs req mgr
  pure ()
