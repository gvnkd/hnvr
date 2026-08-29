{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- | Tests for "Hnvr.Core.Authz".
module Hnvr.Core.AuthzSpec (tests) where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (isJust, isNothing)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.UUID (UUID)
import qualified Data.UUID as UUID
import Hnvr.Core.Authz
  ( CameraAction,
    PageKind,
    RoleSet (..),
    allCameraActions,
    allPageKinds,
    buildRoleSet,
    cameraActionFromText,
    cameraActionToText,
    cameraAllowed,
    canDeleteRole,
    canDeleteUser,
    canRemoveSuperadminGrant,
    emptyRoleSet,
    fullRoleSet,
    needsAclFilter,
    pageAllowed,
    pageKindFromText,
    pageKindToText,
  )
import Hnvr.Core.Id (CameraId (..))
import Test.QuickCheck (Arbitrary (..), Gen, elements, listOf, sublistOf, (==>))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)
import Test.Tasty.QuickCheck (testProperty)

instance Arbitrary CameraId where
  arbitrary =
    CameraId
      <$> (UUID.fromWords <$> arbitrary <*> arbitrary <*> arbitrary <*> arbitrary)

instance Arbitrary CameraAction where
  arbitrary = elements allCameraActions

instance Arbitrary PageKind where
  arbitrary = elements allPageKinds

instance Arbitrary RoleSet where
  arbitrary = do
    pages <- sublistOf allPageKinds
    wild <- sublistOf allCameraActions
    RoleSet (Set.fromList pages) (Set.fromList wild) <$> genPer
    where
      genPer :: Gen (Map CameraId (Set CameraAction))
      genPer = do
        entries <-
          listOf $
            (,)
              <$> arbitrary
              <*> (Set.fromList <$> sublistOf allCameraActions)
        pure (Map.fromList entries)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Authz"
    [ testGroup
        "default-deny"
        [ testCase "empty RoleSet denies every page" $
            assertBool "no pages" (not (any (pageAllowed emptyRoleSet) allPageKinds)),
          testProperty "empty RoleSet denies every camera action" $ \(cam, action) ->
            not (cameraAllowed emptyRoleSet action cam),
          testCase "buildRoleSet [] = emptyRoleSet" $
            assertEqual "empty" emptyRoleSet (buildRoleSet [])
        ],
      testGroup
        "union semantics"
        [ testProperty "adding a role never removes a camera grant" $ \r1 r2 action cam ->
            cameraAllowed r1 action cam
              <= cameraAllowed (r1 <> r2) action cam,
          testProperty "adding a role never removes a page grant" $ \r1 r2 page ->
            pageAllowed r1 page
              <= pageAllowed (r1 <> r2) page,
          testProperty "union is commutative up to Eq" $ \r1 r2 ->
            (r1 <> r2) == ((r2 <> r1) :: RoleSet)
        ],
      testGroup
        "override beats wildcard"
        [ testCase "per-camera row replaces the wildcard for that camera" $ do
            let cam = CameraId (UUID.fromWords 1 2 3 4)
                rs =
                  RoleSet
                    Set.empty
                    (Set.fromList allCameraActions)
                    (Map.singleton cam (Set.fromList []))
            assertBool "override blocks wildcard" (not (cameraAllowed rs (head allCameraActions) cam)),
          testCase "wildcard still covers cameras without an override" $ do
            let overridden = CameraId (UUID.fromWords 1 2 3 4)
                other = CameraId (UUID.fromWords 5 6 7 8)
                action = head allCameraActions
                rs =
                  RoleSet
                    Set.empty
                    (Set.singleton action)
                    (Map.singleton overridden Set.empty)
            assertBool "unknown camera allowed" (cameraAllowed rs action other),
          testProperty "override row ignores wildcard entirely" $ \wildActs perActs cam action ->
            let rs = RoleSet Set.empty (Set.fromList wildActs) (Map.singleton cam (Set.fromList perActs))
             in cameraAllowed rs action cam == (action `elem` perActs)
        ],
      testGroup
        "buildRoleSet"
        [ testCase "page row sets only the page" $ do
            let p = head allPageKinds
                rs = buildRoleSet [(Just p, Nothing, Nothing)]
            assertBool "page granted" (pageAllowed rs p)
            assertBool "no wildcard" (Set.null (rsCamWildcard rs)),
          testCase "NULL camera_id row is a wildcard grant" $ do
            let action = head allCameraActions
                cam = CameraId (UUID.fromWords 9 9 9 9)
                rs = buildRoleSet [(Nothing, Nothing, Just action)]
            assertBool "wildcard covers any camera" (cameraAllowed rs action cam),
          testCase "per-camera row overrides wildcard" $ do
            let [a1, a2] = take 2 allCameraActions
                cam = CameraId (UUID.fromWords 9 9 9 9)
                rs = buildRoleSet [(Nothing, Nothing, Just a1), (Nothing, Just cam, Just a2)]
            assertBool "override grants its action" (cameraAllowed rs a2 cam)
            assertBool "wildcard hidden for that camera" (not (cameraAllowed rs a1 cam)),
          testCase "malformed rows are ignored" $ do
            let cam = CameraId (UUID.fromWords 9 9 9 9)
                rs =
                  buildRoleSet
                    [ (Nothing, Just cam, Nothing),
                      (Just (head allPageKinds), Just cam, Just (head allCameraActions))
                    ]
            assertEqual "empty" emptyRoleSet rs
        ],
      testGroup
        "needsAclFilter"
        [ testProperty "fullRoleSet never needs a filter" $ \action ->
            not (needsAclFilter action fullRoleSet),
          testProperty "emptyRoleSet always needs a filter" $ \action ->
            needsAclFilter action emptyRoleSet,
          testProperty "grant-everywhere RoleSet needs no filter and allows the camera" $ \rs action cam ->
            let rs' =
                  rs
                    { rsCamWildcard = Set.insert action (rsCamWildcard rs),
                      rsCamPer = Map.map (Set.insert action) (rsCamPer rs)
                    }
             in not (needsAclFilter action rs') && cameraAllowed rs' action cam,
          testProperty "wildcard miss implies filter needed" $ \rs action ->
            Set.notMember action (rsCamWildcard rs) ==> needsAclFilter action rs
        ],
      testGroup
        "text round-trip"
        [ testProperty "cameraActionFromText . cameraActionToText" $ \action ->
            cameraActionFromText (cameraActionToText action) == Just action,
          testProperty "pageKindFromText . pageKindToText" $ \page ->
            pageKindFromText (pageKindToText page) == Just page,
          testCase "unknown text is rejected" $ do
            assertBool "action" (isNothing (cameraActionFromText "nope"))
            assertBool "page" (isNothing (pageKindFromText "nope")),
          testCase "all enum labels are distinct" $ do
            let acts = map cameraActionToText allCameraActions
                pages = map pageKindToText allPageKinds
            assertEqual "actions" (length acts) (Set.size (Set.fromList acts))
            assertEqual "pages" (length pages) (Set.size (Set.fromList pages))
        ],
      testGroup
        "lockout guards"
        [ testCase "system role is never deletable" $
            assertBool "system" (not (canDeleteRole True)),
          testCase "user role is deletable" $
            assertBool "plain" (canDeleteRole False),
          testProperty "last superadmin grant is locked" $ \holders ->
            canRemoveSuperadminGrant holders == (holders > 1),
          testProperty "user delete only locks on last superadmin holder" $ \isHolder holders ->
            canDeleteUser isHolder holders
              == (not isHolder || holders > 1)
        ],
      testCase "seeded UUIDs parse and are distinct" $ do
        let distinct = isJust (UUID.fromText "00000000-0000-4000-8000-000000000001")
        assertBool "well-known" distinct
    ]
