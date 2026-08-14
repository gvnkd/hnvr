{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Admin action audit helper (Phase 4, design 06 §"Audit log").
-- One INSERT per mutating controller action; failures are logged and
-- swallowed — audit must never block the action itself.
module Hnvr.Web.Audit
  ( audit,
  )
where

import qualified Control.Exception as E
import Data.Text (Text)
import qualified Data.Text as T
import Data.UUID (UUID)
import Hnvr.Core.Logging (logError)
import IHP.ModelSupport (ModelContext, sqlExec)

-- | Record one audit row. @action@ is dotted (@rule.create@),
-- @targetType@ the table-ish noun (@rule@, @camera@), @targetId@ the
-- affected row's UUID when there is one. The user id is passed in by
-- the controller (it owns the request context).
audit ::
  (?modelContext :: ModelContext) =>
  -- | Acting user's UUID ('Nothing' when unauthenticated — shouldn't
  -- happen behind ensureIsUser, but audit must not throw).
  Maybe UUID ->
  Text ->
  Text ->
  Maybe UUID ->
  IO ()
audit userUuid action targetType targetId = do
  r <-
    E.try $
      sqlExec
        "INSERT INTO audit_log (user_id, action, target_type, target_id) \
        \VALUES (?, ?, ?, ?)"
        (userUuid, action, targetType, targetId)
  case r of
    Right _ -> pure ()
    Left (e :: E.SomeException) ->
      logError ("audit: insert failed for " <> action <> ": " <> T.pack (show e))
