{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /AuditLog — admin-only view over the @audit_log@ table (Phase 4
-- audit trail; the table was a write-only sink until this page).
module Web.Controller.AuditLog
  ( AuditLogController (..),
  )
where

import Generated.Types
import Hnvr.Core.Authz (PageKind (..))
import Hnvr.Web.Authz (ensurePagePerm)
import Hnvr.Web.View.AuditLog.Index
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)

data AuditLogController
  = AuditLogAction
  deriving stock (Eq, Show, Data)

instance AutoRoute AuditLogController

instance Controller AuditLogController where
  beforeAction = ensureIsUser
  action AuditLogAction = do
    -- Roles & ACL (design_docs/13): the settings page grant replaces
    -- the is_admin boolean.
    ensurePagePerm PageSettings
    entries <- query @AuditLog |> orderByDesc #ts |> limit 200 |> fetch
    users <- query @User |> fetch
    render IndexView {..}
