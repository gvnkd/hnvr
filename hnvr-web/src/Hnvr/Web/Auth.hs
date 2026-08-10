{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | IHP v1.6.0 auth wiring.
--
-- In v1.6.0 the old @LoginSupport.User@ class was replaced by:
--
--   * @class HasNewSessionUrl user where newSessionUrl :: Proxy user -> Text@
--     (in @IHP.LoginSupport.Types@)
--   * @type family CurrentUserRecord@
--
-- This module is the entire user-side instance surface — @newSessionUrl@
-- points IHP's @ensureIsUser@ redirect at our 'SessionsController' NewSession
-- action, and @CurrentUserRecord@ tells the auth middleware which model to
-- fetch on each request.
module Hnvr.Web.Auth () where

import Generated.Types
import IHP.LoginSupport.Types (CurrentUserRecord, HasNewSessionUrl (..))
import IHP.Prelude

instance HasNewSessionUrl User where
  newSessionUrl _ = "/NewSession"

type instance CurrentUserRecord = User
