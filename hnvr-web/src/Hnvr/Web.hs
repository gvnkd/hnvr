{-# LANGUAGE OverloadedStrings #-}

-- | HNVR web/leader shared library.
--
-- This module exposes a tiny stable API ('version') for embedders (the
-- @hnvr-leader@ and @hnvr-node@ binaries). IHP wiring lives in
-- 'Hnvr.Web.Config' and 'Hnvr.Web.FrontController'; pull those in
-- transitively by depending on the @hnvr-web@ package directly.
module Hnvr.Web
  ( version,
  )
where

import Data.Text (Text)

-- | Wire the same version as the .cabal file. Bumped manually.
version :: Text
version = "0.1.0.0"
