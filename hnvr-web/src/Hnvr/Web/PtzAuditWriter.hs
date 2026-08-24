{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Leader-side PTZ audit writer (Phase 5). Subscribes
-- @hnvr.ptz.audit@ and inserts each 'PtzAuditRecord' into
-- @ptz_audit_log@. Nodes have no DB access, so the owning host
-- publishes one record per EXECUTED command and the leader persists —
-- rows record execution (with ok/error), not publish intent.
--
-- Raw one-shot pg-simple connection per row would churn; keep one
-- connection open and reconnect on failure (same pattern as
-- 'Hnvr.Web.EventWriter').
module Hnvr.Web.PtzAuditWriter
  ( startPtzAuditWriter,
  )
where

import Control.Concurrent.Async (async)
import Control.Exception (SomeAsyncException (..), SomeException, fromException, throwIO, try)
import Control.Monad (forever)
import Data.Aeson (decodeStrict', encode)
import qualified Data.ByteString.Char8 as BSC
import qualified Data.ByteString.Lazy as BL
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import qualified Data.Text.Lazy.Encoding as TLE
import qualified Database.PostgreSQL.Simple as PG
import Hnvr.Core.Logging (logError, logInfo)
import Hnvr.Core.Ptz (PtzAuditRecord (..), ptzSourceText)
import Hnvr.Nats.Bus (Bus, Message (..))
import qualified Hnvr.Nats.Bus as Bus
import qualified Hnvr.Nats.Subjects as Subjects
import qualified System.Environment as Env

startPtzAuditWriter :: Bus -> IO ()
startPtzAuditWriter bus = do
  _ <- async loop
  logInfo "PtzAuditWriter: subscribed to hnvr.ptz.audit"
  where
    loop = do
      sub <- Bus.subscribe bus Subjects.ptzAudit
      forever $ do
        msg <- Bus.readMessage sub
        r <- try (handle msg)
        case r of
          Right () -> pure ()
          Left (e :: SomeException) -> case fromException e of
            Just (SomeAsyncException _) -> throwIO e
            Nothing -> logError ("PtzAuditWriter: " <> T.pack (show e))

handle :: Message -> IO ()
handle msg = case decodeStrict' (msgPayload msg) of
  Nothing -> logError "PtzAuditWriter: undecodable audit record"
  Just rec' -> insertRecord rec'

-- | One INSERT per record. UUIDs and the source go in as text with
-- inline casts (wire values match the @ptz_source@ enum labels exactly);
-- a malformed record fails the insert and is logged.
insertRecord :: PtzAuditRecord -> IO ()
insertRecord r = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  res <- try $ do
    conn <- PG.connectPostgreSQL dbUrl
    _ <-
      PG.execute
        conn
        "INSERT INTO ptz_audit_log (camera_id, user_id, command, args, source, duration_ms, ok, error) \
        \VALUES (?::uuid, ?::uuid, ?, ?::jsonb, ?::ptz_source, ?, ?, ?)"
        ( parCameraId r,
          parUserId r,
          parCommand r,
          TL.toStrict (TLE.decodeUtf8 (encode (parArgs r))),
          ptzSourceText (parSource r),
          parDurationMs r,
          parOk r,
          parError r
        )
    PG.close conn
  case res of
    Right () -> pure ()
    Left (e :: SomeException) ->
      logError ("PtzAuditWriter: insert failed: " <> T.pack (show e))

defaultDbUrl :: String
defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"
