{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}

-- | Versioned schema migrations via @postgresql-simple-migration@.
--
-- The source of truth is @Application/Schema.sql@ (the same file IHP's
-- schema-compiler reads). We embed its bytes at compile time via
-- @file-embed@ and replay it on a fresh DB at leader boot, wrapped in a
-- transaction and tracked in the @schema_migrations@ table so subsequent
-- boots skip it.
--
-- Schema evolution rules (M2 policy):
--
--   * Add columns / tables / indexes / extensions by editing
--     @Application/Schema.sql@. The leader boot auto-applies new
--     migrations (idempotent — @schema_migrations@ checksum detects
--     tampering with already-applied scripts).
--   * @postgresql-simple-migration@'s @MigrationScript@ mode runs ONE
--     named script. Future changes that need a separate migration step
--     (data backfill, column rename, etc.) should add a new
--     @MigrationScript@ entry in 'runLeaderMigrations' with a fresh name
--     (e.g. @"0002-add-ptz-columns"@).
--   * Don't edit @Application/Schema.sql@ in a way that's incompatible
--     with already-deployed DBs without a corresponding migration. The
--     framework's checksum check will refuse to apply a modified script
--     under the same name — version-bump the script name instead.
module Hnvr.Web.SchemaMigration
  ( runLeaderMigrations,
  )
where

import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as BSC
import Data.FileEmbed (embedFile)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.PostgreSQL.Simple as PG
import Database.PostgreSQL.Simple.Migration
  ( MigrationCommand (MigrationInitialization, MigrationScript),
    MigrationContext (..),
    MigrationResult (..),
    runMigration,
  )
import Database.PostgreSQL.Simple.Transaction (withTransaction)
import Hnvr.Core.Logging (logError, logInfo)
import qualified System.Environment as Env

-- | Embedded migration script from @hnvr-web/migrations/0001-initial.sql@.
-- Path is relative to the package root (CWD at compile time, which
-- cabal sets to the package dir for both cabal-install and nix).
--
-- This file is the runtime-migration version of @Application/Schema.sql@
-- with idempotent guards (@IF NOT EXISTS@, @DO $$ ... EXCEPTION@,
-- @ADD COLUMN IF NOT EXISTS@) so it's safe to run against both fresh
-- DBs and pre-existing DBs that predate M2. Application/Schema.sql
-- stays IHP-parseable for codegen; this file is what the leader
-- actually applies. Keep both files in sync when changing schema.
initialSchemaSql :: ByteString
initialSchemaSql = $(embedFile "migrations/0001-initial.sql")

-- | BRIN index on @segments.start_ts@ (M6). Separate script because
-- 0001-initial had already been applied when the index was added —
-- see the file header.
brinIndexSql :: ByteString
brinIndexSql = $(embedFile "migrations/0002-brin-index.sql")

-- | Phase 4: rules + events tables (design_docs/06 §"Rules"/§"Events").
rulesEventsSql :: ByteString
rulesEventsSql = $(embedFile "migrations/0003-rules-events.sql")

-- | Phase 4: audit log (design_docs/06 §"Audit log").
auditLogSql :: ByteString
auditLogSql = $(embedFile "migrations/0004-audit-log.sql")

-- | zone_motion enum values on rule_kind + event_kind. Was manual-only
-- until Aug 2026 (fresh deploys silently lacked the values); ADD VALUE
-- IF NOT EXISTS makes replay on already-patched DBs a no-op. PG 12+
-- allows ADD VALUE inside the migration transaction as long as the new
-- value is unused in it.
zoneMotionSql :: ByteString
zoneMotionSql = $(embedFile "migrations/0005-zone-motion.sql")

-- | Tombstone column for verified recording deletion
-- (@segments.pending_delete_at@ + partial index). See the file header.
pendingDeleteSql :: ByteString
pendingDeleteSql = $(embedFile "migrations/0006-pending-delete.sql")

-- | Event video clips: cameras.retention_hours, per-rule clip config,
-- @event_clips@ + @event_clip_events@ tables. See the file header.
eventClipsSql :: ByteString
eventClipsSql = $(embedFile "migrations/0007-event-clips.sql")

-- | ONVIF config sync: sparse desired encoder columns on cameras +
-- @camera_drift@ table. See the file header.
onvifConfigSyncSql :: ByteString
onvifConfigSyncSql = $(embedFile "migrations/0008-onvif-config-sync.sql")

-- | Management protocol selector (onvif|dvrip) on cameras.
mgmtProtoSql :: ByteString
mgmtProtoSql = $(embedFile "migrations/0009-mgmt-proto.sql")

-- | Dead schema cleanup: drop never-read/never-written columns, prune
-- zero-emitter event_kind values. See the file header.
cleanupSql :: ByteString
cleanupSql = $(embedFile "migrations/0010-cleanup.sql")

-- | Run all leader-side migrations idempotently. Safe to call on every
-- boot — already-applied migrations are skipped via the
-- @schema_migrations@ table. Returns immediately on success; logs and
-- rethrows on failure so the caller (leader main) fails fast (the
-- leader is non-functional without a schema).
runLeaderMigrations :: IO ()
runLeaderMigrations = do
  dbUrl <- BSC.pack . fromMaybe defaultDbUrl <$> Env.lookupEnv "DATABASE_URL"
  conn <- PG.connectPostgreSQL dbUrl
  -- postgresql-simple-migration requires the caller to wrap in a
  -- transaction; we use the connection-level withTransaction so the
  -- initialization + script run commit atomically.
  withTransaction conn $ do
    -- MigrationInitialization creates the schema_migrations table if
    -- it doesn't exist (idempotent — safe on already-initialized DBs).
    initRes <- runMigration $ MigrationContext MigrationInitialization True conn
    handleResult "initialization" initRes
    -- MigrationScript runs the named script exactly once; checksums
    -- prevent re-runs and detect tampering.
    scriptRes <-
      runMigration $
        MigrationContext (MigrationScript "0001-initial" initialSchemaSql) True conn
    handleResult "0001-initial" scriptRes
    brinRes <-
      runMigration $
        MigrationContext (MigrationScript "0002-brin-index" brinIndexSql) True conn
    handleResult "0002-brin-index" brinRes
    rulesEventsRes <-
      runMigration $
        MigrationContext (MigrationScript "0003-rules-events" rulesEventsSql) True conn
    handleResult "0003-rules-events" rulesEventsRes
    auditRes <-
      runMigration $
        MigrationContext (MigrationScript "0004-audit-log" auditLogSql) True conn
    handleResult "0004-audit-log" auditRes
    zoneRes <-
      runMigration $
        MigrationContext (MigrationScript "0005-zone-motion" zoneMotionSql) True conn
    handleResult "0005-zone-motion" zoneRes
    pendingRes <-
      runMigration $
        MigrationContext (MigrationScript "0006-pending-delete" pendingDeleteSql) True conn
    handleResult "0006-pending-delete" pendingRes
    clipsRes <-
      runMigration $
        MigrationContext (MigrationScript "0007-event-clips" eventClipsSql) True conn
    handleResult "0007-event-clips" clipsRes
    onvifRes <-
      runMigration $
        MigrationContext (MigrationScript "0008-onvif-config-sync" onvifConfigSyncSql) True conn
    handleResult "0008-onvif-config-sync" onvifRes
    mgmtRes <-
      runMigration $
        MigrationContext (MigrationScript "0009-mgmt-proto" mgmtProtoSql) True conn
    handleResult "0009-mgmt-proto" mgmtRes
    cleanupRes <-
      runMigration $
        MigrationContext (MigrationScript "0010-cleanup" cleanupSql) True conn
    handleResult "0010-cleanup" cleanupRes
  PG.close conn
  logInfo "SchemaMigration: migrations applied successfully"
  where
    defaultDbUrl = "postgresql:///hnvr?host=/run/postgresql"

-- | Log + abort on failure. Polymorphic in the error payload type
-- because different 'MigrationCommand' constructors produce different
-- concrete 'MigrationResult' types (@String@ for initialization,
-- @ByteString@ for scripts).
handleResult :: (Show a) => String -> MigrationResult a -> IO ()
handleResult name result =
  case result of
    MigrationSuccess ->
      logInfo ("SchemaMigration: " <> T.pack name <> " OK")
    MigrationError err -> do
      logError ("SchemaMigration: " <> T.pack name <> " failed: " <> T.pack (show err))
      error ("SchemaMigration " <> name <> " failed: " <> show err)
