{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Shared role-assignment checkboxes (@role_\<uuid\>@, consumed by
-- 'Web.Controller.Users.roleParams').
module AdminWeb.View.Users.RoleBoxes (roleCheckboxes) where

import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Generated.Types
import IHP.ModelSupport (Id' (..))
import IHP.ViewPrelude

roleCheckboxes :: [Role] -> [UUID] -> Html
roleCheckboxes roles assigned =
  [hsx|
    <div class="card"><div class="card-body">
      {forEach roles box}
    </div></div>
  |]
  where
    box role =
      [hsx|
        <label class="check">
          <input type="checkbox" name={nameAttr} checked={checkedAttr} />
          <span class="mono">{role.name}</span>
          <span class="muted text-sm">{role.description}</span>
        </label>
      |]
      where
        nameAttr = "role_" <> UUID.toText rid
        checkedAttr = rid `elem` assigned
        rid = case role |> get #id of Id u -> u
