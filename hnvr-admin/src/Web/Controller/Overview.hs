{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | @/@ + @/Overview@ — admin landing: counts + recent admin_audit.
module Web.Controller.Overview
  ( OverviewController (..),
  )
where

import AdminWeb.View.Overview.Index
import Database.PostgreSQL.Simple.Types (Only (..))
import Generated.Types
import Hnvr.Web.Auth ()
import Hnvr.Web.Authz (ensureSuperadmin)
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)

data OverviewController
  = OverviewAction
  deriving stock (Eq, Show, Data)

instance AutoRoute OverviewController

instance Controller OverviewController where
  beforeAction = ensureIsUser
  action OverviewAction = do
    ensureSuperadmin
    nUsers <- scalarCount "SELECT COUNT(*)::int FROM users"
    nRoles <- scalarCount "SELECT COUNT(*)::int FROM roles"
    nHolders <- scalarCount "SELECT COUNT(DISTINCT user_id)::int FROM user_roles"
    entries <- query @AdminAudit |> orderByDesc #createdAt |> limit 50 |> fetch
    render IndexView {..}
    where
      scalarCount q = do
        rows <- sqlQuery q ()
        pure (case rows of [Only n] -> n; _ -> 0)
