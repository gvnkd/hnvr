{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE NoImplicitPrelude #-}

-- | /ShowProfile — the logged-in user's own settings (Phase: web UI
-- timezones). AutoRoute maps:
--
--   * 'ShowProfileAction'   → @/ShowProfile@ (form)
--   * 'UpdateProfileAction' → @/UpdateProfile@ (POST)
--
-- The timezone is an IANA name (@Europe/Berlin@); empty means
-- browser-local (client-side fallback). Server-side validation is a
-- charset/length sanity check only — the canonical zone list lives in
-- the browser (@Intl.supportedValuesOf@), no tz database server-side.
module Web.Controller.Profile
  ( ProfileController (..),
  )
where

import Data.Aeson (object, (.=))
import Data.Char (isAlphaNum)
import qualified Data.Text as T
import Data.UUID (UUID)
import Generated.Types
import Hnvr.Web.Audit (audit)
import Hnvr.Web.Auth ()
import Hnvr.Web.View.Profile.Show
import IHP.ControllerPrelude
import IHP.LoginSupport.Helper.Controller (currentUser, currentUserOrNothing, ensureIsUser)
import IHP.ModelSupport (Id' (Id))

data ProfileController
  = ShowProfileAction
  | UpdateProfileAction
  deriving stock (Eq, Show, Data)

instance AutoRoute ProfileController

instance Controller ProfileController where
  beforeAction = ensureIsUser

  action ShowProfileAction = do
    let user = currentUser
    render ShowView {..}
  action UpdateProfileAction = do
    let user = currentUser
    case (,) <$> normalizeTz (T.strip (param @Text "timezone")) <*> normalizeLocale (T.strip (param @Text "locale")) of
      Nothing -> do
        setErrorMessage "Invalid timezone or locale name"
        redirectTo ShowProfileAction
      Just (mtz, mloc) -> do
        _ <- user |> set #timezone mtz |> set #locale mloc |> updateRecord
        audit currentUserUuid "profile.update" "user" (userUuidOf user) (Just (object ["timezone" .= mtz, "locale" .= mloc]))
        setSuccessMessage "Profile saved"
        redirectTo ShowProfileAction

-- | Empty → NULL (browser default). Otherwise accept IANA-ish names:
-- letters/digits plus @_@ @-@ @/@ @+@, 1..64 chars.
normalizeTz :: Text -> Maybe (Maybe Text)
normalizeTz t
  | T.null t = Just Nothing
  | T.length t > 64 = Nothing
  | T.all (\c -> isAlphaNum c || c `elem` ("_/-+" :: String)) t = Just (Just t)
  | otherwise = Nothing

-- | Empty → NULL (browser locale). Otherwise accept BCP 47-ish tags:
-- letters/digits plus @-@ @_@ (de-DE, zh-Hant-TW), 1..35 chars.
normalizeLocale :: Text -> Maybe (Maybe Text)
normalizeLocale t
  | T.null t = Just Nothing
  | T.length t > 35 = Nothing
  | T.all (\c -> isAlphaNum c || c `elem` ("-_" :: String)) t = Just (Just t)
  | otherwise = Nothing

userUuidOf :: User -> Maybe UUID
userUuidOf u = case u |> get #id of Id uuid -> Just uuid

-- | Acting user's UUID for audit rows (Nothing when unauthenticated;
-- ensureIsUser gates these actions anyway).
currentUserUuid :: (?request :: Request) => Maybe UUID
currentUserUuid = case currentUserOrNothing of
  Nothing -> Nothing
  Just u -> case u |> get #id of Id uuid -> Just uuid
