{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | @admin_audit@ writes (design_docs/13: every admin-service mutation
-- lands here; mirrors the PTZ audit pattern). Raw insert via the IHP
-- pool — the table has a Generated model but the actor/payload are
-- simpler to pass positionally.
module AdminWeb.Audit
  ( auditAdmin,
  )
where

import Data.Aeson (Value)
import Data.Text (Text)
import Data.UUID (UUID)
import Generated.Types
import Hnvr.Web.Auth ()
import IHP.LoginSupport.Helper.Controller (currentUserOrNothing)
import IHP.ModelSupport (Id' (Id), ModelContext, sqlExec)
import IHP.Prelude
import Network.Wai (Request)

-- | Write one admin_audit row. Actor = the current session user (NULL
-- for CLI/bootstrap paths).
auditAdmin :: (?modelContext :: ModelContext, ?request :: Request) => Text -> Text -> Maybe Text -> Maybe Value -> IO ()
auditAdmin action objectKind objectId payload = do
  let actor = case (currentUserOrNothing :: Maybe User) of
        Just u -> case u |> get #id of Id uuid -> Just uuid
        Nothing -> Nothing
  _ <-
    sqlExec
      "INSERT INTO admin_audit (actor_id, action, object_kind, object_id, payload) \
      \VALUES (?, ?, ?, ?, ?)"
      (actor :: Maybe UUID, action, objectKind, objectId, payload)
  pure ()
