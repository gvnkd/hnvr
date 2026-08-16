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
import Hnvr.Web.View.AuditLog.Index
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (currentUserOrNothing, ensureIsUser)

data AuditLogController
  = AuditLogAction
  deriving stock (Eq, Show, Data)

instance AutoRoute AuditLogController

instance Controller AuditLogController where
  beforeAction = ensureIsUser
  action AuditLogAction = do
    let isAdmin = maybe False (.isAdmin) (currentUserOrNothing @User)
    if not isAdmin
      then do
        setErrorMessage "Admin only"
        redirectToPath "/"
      else do
        entries <- query @AuditLog |> orderByDesc #ts |> limit 200 |> fetch
        users <- query @User |> fetch
        render IndexView {..}
