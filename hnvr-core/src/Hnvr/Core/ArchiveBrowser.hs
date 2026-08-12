{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Pure decision logic for the @/Archive@ browser.
--
-- Extracted from @Web.Controller.Archive@ per the S3 pattern
-- (MEMORIES pitfall #14): @hnvr-web@ can't be cabal-tested, so any
-- logic worth a test suite must live in a pure @Hnvr.Core.*@ module.
-- This module owns four concerns:
--
-- 1. 'paginate' — page math (total pages, page clamping, slicing).
-- 2. 'resolveBrowseWindow' — defaults + clamping the @from\/to@ window.
-- 3. 'browseQueryString' — round-tripping filter params through URLs
--    (so destructive actions can redirect back to the same filtered
--    view instead of dropping the user to defaults).
-- 4. 'parseWhen' — accepting ISO 8601 and the @datetime-local@ form
--    that the filter @\<input\>@ emits.
module Hnvr.Core.ArchiveBrowser
  ( -- * Pagination
    Page (..),
    paginate,
    pageCount,
    clampPage,

    -- * Browse window
    resolveBrowseWindow,
    browseWindowMax,
    BrowseNotice (..),

    -- * Query string
    browseQueryString,

    -- * Time parsing
    parseWhen,
  )
where

import Control.Applicative ((<|>))
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime)
import Data.Time.Format (defaultTimeLocale, parseTimeM)
import Data.Time.Format.ISO8601 (iso8601ParseM)

-- | Result of paginating a list. @pageItems@ is the slice for the
-- requested page; @pageTotal@ is the page count (≥1, even for empty
-- input, so the UI never renders "page 1 of 0"); @pageItemTotal@ is the
-- full unfiltered count of items in the input.
data Page a = Page
  { pageItems :: [a],
    pageNumber :: Int,
    pageTotal :: Int,
    pageItemTotal :: Int
  }
  deriving stock (Eq, Show)

-- | Total page count for a given page size and item count. Always ≥1
-- (the @/Archive@ UI shows "1/1" for an empty table rather than the
-- mathematically-correct-but-jarring "1/0").
pageCount :: Int -> Int -> Int
pageCount size total
  | size <= 0 = 1
  | otherwise = max 1 ((total + size - 1) `div` size)

-- | Clamp a page number to the valid range @[1, pages]@. Treats @<1@
-- as @1@ (a stale link or user-typed @?page=0@ should not blow up).
clampPage :: Int -> Int -> Int
clampPage pages page = max 1 (min pages (max 1 page))

-- | Pure pagination: sort by the supplied projection (descending — the
-- archive browser shows newest recordings first), clamp the page
-- number, slice the list, and bundle the metadata the view needs.
--
-- >>> paginate 10 1 ["a","b","c"]
-- Page {pageItems = ["a","b","c"], pageNumber = 1, pageTotal = 1, pageItemTotal = 3}
--
-- >>> paginate 2 2 ["a","b","c","d","e"]
-- Page {pageItems = ["c","d"], pageNumber = 2, pageTotal = 3, pageItemTotal = 5}
--
-- >>> paginate 10 99 ["a","b"]
-- Page {pageItems = ["a","b"], pageNumber = 1, pageTotal = 1, pageItemTotal = 2}
paginate ::
  -- | page size (≤0 treated as 1)
  Int ->
  -- | requested page (clamped to @[1, pageCount]@)
  Int ->
  -- | all items, assumed already sorted the way the caller wants
  [a] ->
  Page a
paginate sizeRequested pageRequested items =
  let size = max 1 sizeRequested
      total = length items
      pages = pageCount size total
      page = clampPage pages pageRequested
      slice = take size (drop ((page - 1) * size) items)
   in Page
        { pageItems = slice,
          pageNumber = page,
          pageTotal = pages,
          pageItemTotal = total
        }

-- | Hard cap on the @/Archive@ browser window. Larger ranges are
-- clamped with a 'BrowseClamped' notice.
-- clamped with a 'BrowseClamped' notice.
browseWindowMax :: NominalDiffTime
browseWindowMax = 24 * 3600

-- | User-facing notice attached to a resolved window. The view renders
-- this as a warning badge so the user knows their filter was rewritten.
data BrowseNotice
  = NoNotice
  | BrowseClamped Text
  deriving stock (Eq, Show)

-- | Default the @from\/to@ window to "last 24 h" when absent and clamp
-- over-wide windows down to 'browseWindowMax'. Pure so it can be tested
-- without IO or a model context.
--
-- Invariants on the output:
--
-- * @(Just f, Just t)@ with @t > f@ and @(t - f) ≤ 'browseWindowMax'@
-- * One of @Just@ when the user supplied only one side; the other is
--   derived to keep the window at or below the cap.
-- * @(Nothing, Nothing)@ → last @'browseWindowMax'@ ending at @now@.
resolveBrowseWindow ::
  UTCTime ->
  Maybe UTCTime ->
  Maybe UTCTime ->
  (Maybe UTCTime, Maybe UTCTime, BrowseNotice)
resolveBrowseWindow now mFrom mTo =
  case (mFrom, mTo) of
    (Just f, Just t)
      | t > f && diffUTCTime t f > browseWindowMax ->
          (Just f, Just (addUTCTime browseWindowMax f), BrowseClamped "Window clamped to 24h")
      | t > f -> (Just f, Just t, NoNotice)
      | otherwise -> (Just (addUTCTime (-browseWindowMax) now), Just now, BrowseClamped "Invalid from/to; showing last 24h")
    (Just f, Nothing) -> (Just f, Just (addUTCTime browseWindowMax f), NoNotice)
    (Nothing, Just t) -> (Just (addUTCTime (-browseWindowMax) t), Just t, NoNotice)
    (Nothing, Nothing) -> (Just (addUTCTime (-browseWindowMax) now), Just now, NoNotice)

-- | Build a @?a=1&b=2@ query tail (without the leading @?@) from the
-- five archive filter params. Used to round-trip filters through
-- destructive redirects ('PurgeRecordingAction' → @/Archive@) so the
-- user lands back on the same filtered view minus the deleted row.
--
-- 'Nothing' / 'mempty' values are omitted entirely (not emitted as
-- @&q=@), which matches the controller's @nonemptyParam@ treatment on
-- the read side.
browseQueryString ::
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Text ->
  Maybe Int ->
  Text
browseQueryString mCam mFrom mTo mQ mMinDur =
  T.concat
    [ param "cameraId" mCam,
      param "from" mFrom,
      param "to" mTo,
      param "q" mQ,
      param "minDuration" (tshow <$> mMinDur)
    ]
  where
    param _ Nothing = ""
    param name (Just v) = "&" <> name <> "=" <> v
    tshow = T.pack . show

-- | Accept full ISO 8601 (e.g. @2026-08-11T14:30:00Z@) and the
-- @datetime-local@ form (@2026-08-11T14:30[:SS]@, assumed UTC) emitted
-- by the filter @\<input type="datetime-local"\>@. Returns 'Nothing'
-- on anything else so the controller can fall back to the default
-- window.
parseWhen :: Text -> Maybe UTCTime
parseWhen t =
  iso8601ParseM s
    <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M" s
    <|> parseTimeM True defaultTimeLocale "%Y-%m-%dT%H:%M:%S" s
  where
    s = T.unpack t
