{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /Rules — CV rule CRUD (Phase 4).
--
--   * 'RulesAction'       → @/Rules@ (list, optional camera filter)
--   * 'NewRuleAction'     → @/NewRule?ruleCameraId=…@ (form + drawing canvas)
--   * 'CreateRuleAction'  → @/CreateRule@ (POST)
--   * 'EditRuleAction'    → @/EditRule?ruleId=…@
--   * 'UpdateRuleAction'  → @/UpdateRule?ruleId=…@ (POST)
--   * 'PurgeRuleAction'   → @/PurgeRule?ruleId=…@ (POST — not
--     @Delete*@: AutoRoute maps Delete* to HTTP DELETE only and our
--     forms don't load ihp.js's method-override, pitfall #82)
--
-- Geometry (line endpoints / zone polygon) is drawn on a canvas over
-- the camera's latest analysis frame (@/debug-frame/<uuid>@) and
-- posted as a normalized-coords JSON string (design 06).
--
-- Every mutation republishes the camera's assign payload with the
-- fresh rule set ('publishRuleRefresh') — the owning host restarts the
-- analysis pair with the new rules. Boot-time propagation is via the
-- SnapshotResponder (rules joined there).
module Web.Controller.Rules
  ( RulesController (..),
  )
where

import Data.Aeson (decode, object, (.=))
import qualified Data.ByteString.Lazy as BL
import Data.IORef (readIORef)
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (getCurrentTime)
import Data.UUID (UUID)
import Generated.Types
import Hnvr.Core.Authz (CameraAction (..), PageKind (..))
import Hnvr.Core.Id (CameraId (..))
import Hnvr.Web.Audit (audit)
import Hnvr.Web.Auth ()
import Hnvr.Web.Authz (aclCameraIds, aclFilterCameras, ensurePagePerm, ensurePerm, toCameraId)
import Hnvr.Web.BusRegistry (busRegistry)
import Hnvr.Web.CommandTypes (cameraIdOf, republishAssign)
import Hnvr.Web.View.Rules.Edit
import Hnvr.Web.View.Rules.Index
import Hnvr.Web.View.Rules.New
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (ensureIsUser)
import IHP.ModelSupport (Id' (Id))
import Text.Read (readMaybe)

data RulesController
  = RulesAction
  | NewRuleAction {ruleCameraId :: !(Id Camera)}
  | CreateRuleAction
  | EditRuleAction {ruleId :: !(Id Rule)}
  | UpdateRuleAction {ruleId :: !(Id Rule)}
  | PurgeRuleAction {ruleId :: !(Id Rule)}
  deriving stock (Eq, Show, Data)

instance AutoRoute RulesController

instance Controller RulesController where
  beforeAction = ensureIsUser

  action RulesAction = do
    ensurePagePerm PageRules
    -- Rules name their camera — listing is scoped to the subject's
    -- manage_events ACL (rules ARE event policy; design_docs/13).
    mAclIds <- aclCameraIds ManageEvents
    rules <-
      ( case mAclIds of
          Nothing -> id
          Just ids -> filterWhereIn (#cameraId, ids)
      )
        (query @Rule |> orderByDesc #createdAt)
        |> fetch
    cameras <- aclFilterCameras ManageEvents (query @Camera |> orderBy #slug) >>= fetch
    render IndexView {..}
  action NewRuleAction {ruleCameraId} = do
    ensurePerm ManageEvents (toCameraId ruleCameraId)
    camera <- fetch ruleCameraId
    render NewView {..}
  action CreateRuleAction = do
    camera <- fetch (param @(Id Camera) "camera_id")
    ensurePerm ManageEvents (toCameraId (camera |> get #id))
    let rule = buildRuleFromParams (newRecord @Rule |> set #cameraId (camUuidOf camera))
    rule' <- rule |> createRecord
    audit currentUserUuid "rule.create" "rule" (Just (ruleUuid rule')) (Just (object ["name" .= rule'.name, "camera_slug" .= camera.slug]))
    publishRuleRefresh camera
    setSuccessMessage "Rule created"
    redirectTo EditRuleAction {ruleId = rule' |> get #id}
  action EditRuleAction {ruleId} = do
    rule <- fetch ruleId
    ensurePerm ManageEvents (CameraId rule.cameraId)
    camera <- fetch (Id rule.cameraId :: Id Camera)
    render EditView {..}
  action UpdateRuleAction {ruleId} = do
    rule <- fetch ruleId
    ensurePerm ManageEvents (CameraId rule.cameraId)
    now <- liftIO getCurrentTime
    rule' <- (buildRuleFromParams rule |> set #updatedAt now) |> updateRecord
    audit currentUserUuid "rule.update" "rule" (Just (ruleUuid rule')) (Just (object ["name" .= rule'.name]))
    camera <- fetch (Id rule.cameraId :: Id Camera)
    publishRuleRefresh camera
    setSuccessMessage "Rule updated"
    redirectTo EditRuleAction {ruleId = rule' |> get #id}
  action PurgeRuleAction {ruleId} = do
    rule <- fetch ruleId
    ensurePerm ManageEvents (CameraId rule.cameraId)
    camera <- fetch (Id rule.cameraId :: Id Camera)
    deleteRecord rule
    audit currentUserUuid "rule.delete" "rule" (Just (ruleUuid rule)) (Just (object ["name" .= rule.name]))
    publishRuleRefresh camera
    setSuccessMessage "Rule deleted"
    redirectTo RulesAction

-- | Populate a Rule record from form params. @geometry@ arrives as a
-- JSON string built by the drawing canvas (line:
-- @{a:[x,y],b:[x,y],direction:…}@; zone: @{polygon:[[x,y],…]}@).
buildRuleFromParams :: (?request :: Request) => Rule -> Rule
buildRuleFromParams rule =
  rule
    |> set #name (param @Text "name")
    |> set #kind kindEnum
    |> set #geometry geometryValue
    |> set #classes (parseClasses (param @Text "classes"))
    |> set #cooldownMs (param @Int "cooldown_ms")
    |> set #clipPrerollSec (param @Int "clip_preroll_sec")
    |> set #clipPostrollSec (param @Int "clip_postroll_sec")
    |> set #clipRetentionHours clipRetention
    |> set #enabled (paramOrFalse "enabled")
  where
    -- The checkbox gates clip recording; the hours input only matters
    -- when it's on. Unchecked → NULL → the node's ClipRecorder ignores
    -- this rule entirely.
    clipRetention
      | paramOrFalse "clip_enabled" = Just (param @Int "clip_retention_hours")
      | otherwise = Nothing
    kindEnum = case param @Text "kind" of
      "zone_enter" -> RuleKindZoneEnter
      "zone_exit" -> RuleKindZoneExit
      "zone_inside" -> RuleKindZoneInside
      "zone_motion" -> RuleKindZoneMotion
      _ -> LineCross
    geometryValue =
      fromMaybe (object []) (decode (BL.fromStrict (TE.encodeUtf8 (param @Text "geometry"))))
    parseClasses = mapMaybe (readMaybe . T.unpack) . T.splitOn ","
    paramOrFalse name = paramOrNothing @Text name == Just "on"

-- | Republish the camera's assign payload with its fresh rules so the
-- owning host restarts the analysis pair with them. No-op when the
-- camera is unassigned or the bus is down (boot snapshot still covers
-- the next restart).
publishRuleRefresh :: (?modelContext :: ModelContext) => Camera -> IO ()
publishRuleRefresh camera = do
  mBus <- liftIO (readIORef busRegistry)
  forM_ mBus $ \bus -> republishAssign bus camera

-- | Raw UUID of a camera row (Rule.cameraId is a bare UUID, not an
-- IHP 'Id').
camUuidOf :: Camera -> UUID
camUuidOf cam = case cam |> get #id of Id u -> u

ruleUuid :: Rule -> UUID
ruleUuid r = case r |> get #id of Id u -> u

-- | Acting user's UUID for audit rows (Nothing when unauthenticated;
-- ensureIsUser gates these actions anyway).
currentUserUuid :: (?request :: Request) => Maybe UUID
currentUserUuid = case currentUserOrNothing of
  Nothing -> Nothing
  Just u -> case u |> get #id of Id uuid -> Just uuid
