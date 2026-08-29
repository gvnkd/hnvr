{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | Shared role form body: name/description, page grant checkboxes,
-- wildcard camera-action checkboxes, and the per-camera override matrix
-- (design_docs/13: a per-camera row set REPLACES the wildcard for that
-- camera). Checkbox names are consumed by 'Web.Controller.Roles.grantParams'.
module AdminWeb.View.Roles.Form (roleFormFields) where

import AdminWeb.Grants (RoleGrants (..))
import Data.Text (Text)
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Generated.Types
import Hnvr.Core.Authz
import IHP.ModelSupport (Id' (..))
import IHP.ViewPrelude

roleFormFields :: Role -> RoleGrants -> [Camera] -> Html
roleFormFields role grants cameras =
  [hsx|
    <div class="field">
      <label for="name">Name</label>
      <input class="input" id="name" name="name" value={role.name} required />
    </div>
    <div class="field">
      <label for="description">Description</label>
      <input class="input" id="description" name="description" value={role.description} />
    </div>

    <div class="section-h">Pages</div>
    <div class="card"><div class="card-body">
      {forEach allPageKinds pageBox}
    </div></div>

    <div class="section-h">Camera actions — default (all cameras)</div>
    <div class="card"><div class="card-body">
      {forEach allCameraActions wildBox}
      <div class="hint mt-2">Wildcard grants apply to every camera without an override below.</div>
    </div></div>

    <div class="section-h">Per-camera overrides</div>
    <div class="card"><div class="card-body">
      <div class="hint mb-4">An override replaces the wildcard for that camera: only the checked actions are granted.</div>
      {forEach cameras overrideRow}
    </div></div>
  |]
  where
    pageBox p =
      [hsx|
        <label class="check">
          <input type="checkbox" name={pageName p} checked={p `elem` grants.rgPages} />
          <span>{pageKindToText p}</span>
        </label>
      |]
    pageName p = "page_" <> pageKindToText p :: Text

    wildBox a =
      [hsx|
        <label class="check">
          <input type="checkbox" name={wildName a} checked={a `elem` grants.rgWildcard} />
          <span>{cameraActionToText a}</span>
        </label>
      |]
    wildName a = "wild_" <> cameraActionToText a :: Text

    overrideRow cam =
      [hsx|
        <div class="ovr-row mb-4">
          <label class="check t-strong">
            <input type="checkbox" name={ovrOn cam} checked={hasOverride cam} />
            <span class="mono">{cam.slug}</span>
          </label>
          <div class="ovr-actions">{forEach allCameraActions (ovrBox cam)}</div>
        </div>
      |]
    ovrBox cam a =
      [hsx|
        <label class="check">
          <input type="checkbox" name={ovrName cam a} checked={hasOvr cam a} />
          <span>{cameraActionToText a}</span>
        </label>
      |]
    ovrOn cam = "ovr_on_" <> UUID.toText (camUuid cam) :: Text
    ovrName cam a = "ovr_" <> UUID.toText (camUuid cam) <> "_" <> cameraActionToText a :: Text
    hasOverride cam = camUuid cam `elem` map fst (grants.rgOverrides)
    hasOvr cam a = maybe False (a `elem`) (lookup (camUuid cam) (grants.rgOverrides))
    camUuid c = case c |> get #id of Id u -> u :: UUID
