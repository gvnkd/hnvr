{-# LANGUAGE OverloadedStrings #-}

-- | Entry point for the @hnvr-admin@ binary (design_docs/13, M3).
--
--   * @hnvr-admin@ / @hnvr-admin serve@ — run the admin web service
--     (HNVR_ADMIN_LISTEN : HNVR_ADMIN_PORT, default 127.0.0.1:18010).
--   * @hnvr-admin create-user --email E --password P@ — bootstrap a
--     superadmin user without any UI (first-run chicken-and-egg).
--   * @--version@ / @--help@ — print and exit. Unlike the leader
--     (pitfall #122), this binary parses CLI args BEFORE touching IHP,
--     so these never boot the app.
module Main (main) where

import AdminWeb.Bootstrap (bootstrapUser, enableGuest)
import AdminWeb.Config (config)
import AdminWeb.FrontController ()
import AdminWeb.Server (runAdmin)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Hnvr.Core.Logging (logInfo)
import Hnvr.Web (versionText)
import Hnvr.Web.SchemaMigration (runLeaderMigrations)
import qualified System.Environment as Env
import System.Exit (die)
import System.IO (stdout)

-- brings the orphan FrontController RootApplication instance

main :: IO ()
main = do
  args <- Env.getArgs
  case args of
    ["--version"] -> TIO.putStrLn versionText
    ["--help"] -> TIO.putStrLn usage
    ["create-user", "--email", email, "--password", password] ->
      bootstrap (T.pack email) (T.pack password)
    "create-user" : _ -> die (T.unpack usage)
    ["enable-guest"] -> do
      runLeaderMigrations
      enableGuest
    [] -> serve
    ["serve"] -> serve
    _ -> die (T.unpack usage)
  where
    serve = do
      logInfo ("starting hnvr-admin, " <> versionText)
      -- Shared DB with the leader; migrations are idempotent.
      runLeaderMigrations
      runAdmin config
    bootstrap email password = do
      runLeaderMigrations
      bootstrapUser email password
      logInfo ("hnvr-admin: bootstrapped superadmin " <> email)

usage :: Text
usage =
  "hnvr-admin — HNVR management service\n\
  \  hnvr-admin [serve]                          run the admin web service\n\
  \  hnvr-admin create-user --email E --password P   create/update a superadmin user\n\
  \  hnvr-admin enable-guest                     re-create the guest role (anonymous access) with default grants\n\
  \  hnvr-admin --version\n\
  \  hnvr-admin --help"
