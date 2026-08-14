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
