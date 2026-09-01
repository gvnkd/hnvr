{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Reverse-proxy sub-path glue for hnvr-admin (design_docs/13;
-- HNVR_ADMIN_BASE_URL, e.g. @https://nvr.example.com/admin@).
--
-- The WAI machinery is shared with the leader in "Hnvr.Web.BasePath"
-- (re-exported here so existing admin imports keep working); this
-- module only adds the admin-specific env knob. See
-- "Hnvr.Core.BasePath" for the four surfaces a sub-path mount must
-- cover.
module AdminWeb.BasePath
  ( -- * Admin env knob
    basePathFromEnv,

    -- * Shared WAI glue ("Hnvr.Web.BasePath")
    stripBasePathMiddleware,
    urlFor,
    requestBasePath,
  )
where

import Data.Text (Text)
import Hnvr.Core.BasePath (splitBaseUrl)
import Hnvr.Web.BasePath (requestBasePath, stripBasePathMiddleware, urlFor)
import IHP.Prelude
import qualified System.Environment as Env

-- | The mount prefix derived from @HNVR_ADMIN_BASE_URL@ (@\"\"@ when
-- unset or path-less — the app then behaves exactly as before).
basePathFromEnv :: IO Text
basePathFromEnv = do
  mUrl <- Env.lookupEnv "HNVR_ADMIN_BASE_URL"
  pure (maybe "" (snd . splitBaseUrl . cs) mUrl)
