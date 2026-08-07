{-# LANGUAGE OverloadedStrings #-}

-- | HNVR web/leader shared library.
--
-- Currently minimal — exposes only 'version'. Real IHP application
-- scaffolding (FrontController, Controllers, Views, Schema.sql) lands in
-- Phase 0 / Phase 1 via @ihp new@ against this package.
--
-- See @design_docs/05-web-and-live-view.md@ for the eventual structure.
module Hnvr.Web
  ( version
  ) where

import Data.Text (Text)

-- | Wire the same version as the .cabal file. Bumped manually.
version :: Text
version = "0.1.0.0"
