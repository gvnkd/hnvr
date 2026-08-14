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

import Data.Aeson (decode, object)
import qualified Data.ByteString.Lazy as BL
import Data.IORef (readIORef)
import Data.Maybe (fromMaybe, mapMaybe)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Generated.Types
import Hnvr.Core.CameraSnapshot (RuleSnapshot (..))
import qualified Hnvr.Nats.Bus as Bus
import Hnvr.Nats.Subjects (commandAssign)
import Hnvr.Web.Auth ()
import Hnvr.Web.BusRegistry (busRegistry)
import Hnvr.Web.CommandTypes (AssignPayload (..), cameraIdOf, projectCameraWithRules)
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
    rules <- query @Rule |> orderByDesc #createdAt |> fetch
    cameras <- query @Camera |> orderBy #slug |> fetch
    render IndexView {..}
  action NewRuleAction {ruleCameraId} = do
    camera <- fetch ruleCameraId
    render NewView {..}
  action CreateRuleAction = do
    camera <- fetch (param @(Id Camera) "camera_id")
    let rule = buildRuleFromParams (newRecord @Rule |> set #cameraId (camUuidOf camera))
    rule' <- rule |> createRecord
    publishRuleRefresh camera
    setSuccessMessage "Rule created"
    redirectTo EditRuleAction {ruleId = rule' |> get #id}
  action EditRuleAction {ruleId} = do
    rule <- fetch ruleId
    camera <- fetch (Id rule.cameraId :: Id Camera)
    render EditView {..}
  action UpdateRuleAction {ruleId} = do
    rule <- fetch ruleId
    rule' <- buildRuleFromParams rule |> updateRecord
    camera <- fetch (Id rule.cameraId :: Id Camera)
    publishRuleRefresh camera
    setSuccessMessage "Rule updated"
    redirectTo EditRuleAction {ruleId = rule' |> get #id}
  action PurgeRuleAction {ruleId} = do
    rule <- fetch ruleId
    camera <- fetch (Id rule.cameraId :: Id Camera)
    deleteRecord rule
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
    |> set #enabled (paramOrFalse "enabled")
  where
    kindEnum = case param @Text "kind" of
      "zone_enter" -> RuleKindZoneEnter
      "zone_exit" -> RuleKindZoneExit
      "zone_inside" -> RuleKindZoneInside
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
publishRuleRefresh camera =
  forM_ camera.assignedHost $ \host -> do
    mBus <- liftIO (readIORef busRegistry)
    forM_ mBus $ \bus -> do
      rules <- query @Rule |> filterWhere (#cameraId, camUuidOf camera) |> filterWhere (#enabled, True) |> fetch
      let snaps = map toSnapshot rules
      forM_ (projectCameraWithRules snaps camera) $ \snap ->
        liftIO
          $ Bus.publishJson bus (commandAssign camera.slug)
          $ AssignPayload
            { apSlug = camera.slug,
              apHost = host,
              apCameraId = camUuidOf camera,
              apCamera = Just snap
            }

-- | Rule row → wire shape (geometry passes through as JSON).
toSnapshot :: Rule -> RuleSnapshot
toSnapshot rule =
  RuleSnapshot
    { rsId = ruleIdText rule,
      rsKind = kindText rule.kind,
      rsGeometry = rule.geometry,
      rsClasses = rule.classes,
      rsCooldownMs = rule.cooldownMs
    }
  where
    ruleIdText r = case r |> get #id of Id u -> UUID.toText u
    kindText LineCross = "line_cross"
    kindText RuleKindZoneEnter = "zone_enter"
    kindText RuleKindZoneExit = "zone_exit"
    kindText RuleKindZoneInside = "zone_inside"

-- | Raw UUID of a camera row (Rule.cameraId is a bare UUID, not an
-- IHP 'Id').
camUuidOf :: Camera -> UUID
camUuidOf cam = case cam |> get #id of Id u -> u
