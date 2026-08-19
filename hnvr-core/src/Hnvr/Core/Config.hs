{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Application config file (YAML), read once at process start.
--
-- Credentials live here, NOT in the nix flake or shell env — the file is
-- gitignored in dev (@hnvr.yaml@ at the repo root, see
-- @hnvr.example.yaml@) and deployed as a sops-nix secret in production
-- (@services.hnvr.leader.configFile@).
--
-- Resolution order per field: @HNVR_*@ environment variable when set,
-- otherwise the file value. The env-override path keeps integration
-- tests and ad-hoc binary runs (hnvr-capture-loop etc.) working without
-- a file.
--
-- Path resolution: @$HNVR_CONFIG@ when set, else @.\/hnvr.yaml@
-- (CWD-relative — the dev leader runs from the repo root; the systemd
-- unit's WorkingDirectory is the data dir).
--
-- Only the sections with a consumer are parsed today (@s3@); unknown
-- top-level keys are ignored so the file can grow without breaking
-- older binaries.
module Hnvr.Core.Config
  ( AppConfig (..),
    S3Section (..),
    parseAppConfig,
    loadAppConfig,
    loadAppConfigFrom,
    defaultConfigPath,
  )
where

import Control.Exception (throwIO)
import Data.Aeson (FromJSON (..), withObject, (.:), (.:?))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import Data.Yaml (ParseException, decodeEither')
import System.Directory (doesFileExist)
import System.Environment (lookupEnv)

-- | Root of the config file. Every section is optional; consumers
-- fall back to their env vars when the section is absent.
newtype AppConfig = AppConfig
  { acS3 :: Maybe S3Section
  }
  deriving stock (Eq, Show)

-- | @[s3]@ section — SeaweedFS connection. The @ro_*@ pair, when both
-- present, signs browser-facing presigned GET URLs (read-only identity);
-- server-side put/list/delete always uses the primary pair.
data S3Section = S3Section
  { ssEndpoint :: !Text,
    ssAccessKey :: !Text,
    ssSecretKey :: !Text,
    ssBucket :: !Text,
    ssPublicEndpoint :: !(Maybe Text),
    ssRoAccessKey :: !(Maybe Text),
    ssRoSecretKey :: !(Maybe Text)
  }
  deriving stock (Eq, Show)

instance FromJSON AppConfig where
  parseJSON = withObject "AppConfig" $ \o ->
    AppConfig <$> o .:? "s3"

instance FromJSON S3Section where
  parseJSON = withObject "s3" $ \o ->
    S3Section
      <$> o .: "endpoint"
      <*> o .: "access_key"
      <*> o .: "secret_key"
      <*> o .: "bucket"
      <*> o .:? "public_endpoint"
      <*> o .:? "ro_access_key"
      <*> o .:? "ro_secret_key"

-- | Pure parse, for tests. YAML is a JSON superset and 'FromJSON' drives
-- both, so this is the same decoder the file loader uses.
parseAppConfig :: ByteString -> Either String AppConfig
parseAppConfig bs = case decodeEither' bs of
  Left err -> Left (prettyParse err)
  Right cfg -> Right cfg
  where
    prettyParse :: ParseException -> String
    prettyParse = show

-- | Default config path when @$HNVR_CONFIG@ is unset: @hnvr.yaml@ in
-- the process CWD.
defaultConfigPath :: FilePath
defaultConfigPath = "hnvr.yaml"

-- | Load the config file from @$HNVR_CONFIG@ (or 'defaultConfigPath').
-- 'Nothing' when the file does not exist — every consumer then relies
-- on env vars alone. A present-but-malformed file is a hard error:
-- silently ignoring it would fall back to stale env creds.
loadAppConfig :: IO (Maybe AppConfig)
loadAppConfig = do
  mPath <- lookupEnv "HNVR_CONFIG"
  loadAppConfigFrom (fromMaybe defaultConfigPath mPath)

-- | Load from an explicit path. 'Nothing' when absent, throws
-- 'userError' on a parse failure.
loadAppConfigFrom :: FilePath -> IO (Maybe AppConfig)
loadAppConfigFrom path = do
  exists <- doesFileExist path
  if not exists
    then pure Nothing
    else do
      bs <- B.readFile path
      case parseAppConfig bs of
        Left err ->
          throwIO (userError ("config file " <> path <> ": " <> err))
        Right cfg -> pure (Just cfg)
