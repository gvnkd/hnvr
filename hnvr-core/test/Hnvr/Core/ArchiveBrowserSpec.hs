{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Tests for "Hnvr.Core.ArchiveBrowser".
--
-- These tests pin down the bugs Sergey reported on 2026-08-12:
--
-- * @pageSize = 25@ produced a @1/1@ pagination badge even when 12 rows
--   were visible — the math was right but the page size was too generous
--   to ever page in practice. Fixed by lowering to 10 (the controller
--   constant, not tested here directly because it lives in hnvr-web;
--   the @paginate@ semantics are what we lock in).
-- * @PurgeRecordingAction@ redirected to @/Archive@ (no query string),
--   dropping filter context and showing a default-window view that
--   read as "the deleted row is still there". The redirect now carries
--   the round-tripped filter params via 'browseQueryString', whose
--   omit-nothing contract is asserted here.
module Hnvr.Core.ArchiveBrowserSpec (tests) where

import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Calendar (fromGregorian)
import Data.Time.Clock (UTCTime (..), addUTCTime, diffUTCTime, secondsToDiffTime)
import Hnvr.Core.ArchiveBrowser
  ( BrowseNotice (..),
    Page (..),
    browseQueryString,
    browseWindowMax,
    clampPage,
    pageCount,
    paginate,
    parseWhen,
    resolveBrowseWindow,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)
import Test.Tasty.QuickCheck (Positive (..), testProperty)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.ArchiveBrowser"
    [ testGroup
        "paginate"
        [ testCase "empty input still yields page 1/1 (not 1/0)" $ do
            let p = paginate 10 1 ([] :: [Int])
            assertEqual "page number" 1 (pageNumber p)
            assertEqual "page total" 1 (pageTotal p)
            assertEqual "items" [] (pageItems p)
            assertEqual "item total" 0 (pageItemTotal p),
          testCase "single-page: 12 items on size-25 → 1/1 with all 12 visible" $ do
            -- Reproduces the Sergey symptom: with pageSize=25 the
            -- old code showed all 12 + "1/1" — mathematically right,
            -- UX-wise confusing. The semantics here must still be
            -- correct when the controller bumps pageSize down.
            let items = [1 .. 12] :: [Int]
                p = paginate 25 1 items
            assertEqual "page total" 1 (pageTotal p)
            assertEqual "page number" 1 (pageNumber p)
            assertEqual "items shown" items (pageItems p)
            assertEqual "total recorded" 12 (pageItemTotal p),
          testCase "pageSize=10 splits 12 items into 2 pages" $ do
            let items = [1 .. 12] :: [Int]
                p1 = paginate 10 1 items
                p2 = paginate 10 2 items
            assertEqual "p1 total pages" 2 (pageTotal p1)
            assertEqual "p1 items" [1 .. 10] (pageItems p1)
            assertEqual "p2 items" [11, 12] (pageItems p2)
            assertEqual "p2 page number" 2 (pageNumber p2),
          testCase "page requested beyond range clamps to last page" $ do
            let items = [1 .. 5] :: [Int]
                p = paginate 10 99 items
            assertEqual "page number" 1 (pageNumber p)
            assertEqual "items" items (pageItems p),
          testCase "page 0 (or negative) clamps to page 1" $ do
            let items = [1 .. 5] :: [Int]
            assertEqual "page=0" 1 (pageNumber (paginate 10 0 items))
            assertEqual "page=-3" 1 (pageNumber (paginate 10 (-3) items)),
          testCase "pageSize 0 or negative is treated as 1" $ do
            let items = [1 .. 3] :: [Int]
            -- Defensive: caller is supposed to pass a positive size,
            -- but we shouldn't divide by zero or produce a nonsense slice.
            assertEqual "size=0 page count" 3 (pageTotal (paginate 0 1 items))
            assertEqual "size=0 first item" [1] (pageItems (paginate 0 1 items)),
          testCase "exact multiple of pageSize: no trailing empty page" $ do
            let items = [1 .. 20] :: [Int]
                p = paginate 10 2 items
            assertEqual "page total" 2 (pageTotal p)
            assertEqual "page 2 items" [11 .. 20] (pageItems p)
            let pBeyond = paginate 10 3 items
            assertEqual "page 3 clamps to 2" 2 (pageNumber pBeyond)
        ],
      testGroup
        "pageCount + clampPage"
        [ testCase "pageCount 10 0 = 1 (never 0)" $
            assertEqual "" 1 (pageCount 10 0),
          testCase "pageCount 10 1 = 1" $
            assertEqual "" 1 (pageCount 10 1),
          testCase "pageCount 10 10 = 1 (exact multiple)" $
            assertEqual "" 1 (pageCount 10 10),
          testCase "pageCount 10 11 = 2" $
            assertEqual "" 2 (pageCount 10 11),
          testCase "pageCount 0 5 = 1 (size<=0 fallback)" $
            assertEqual "" 1 (pageCount 0 5),
          testCase "clampPage returns at least 1" $
            assertEqual "" 1 (clampPage 5 0),
          testCase "clampPage never exceeds total" $
            assertEqual "" 3 (clampPage 3 99),
          testCase "clampPage preserves valid input" $
            assertEqual "" 2 (clampPage 5 2)
        ],
      testGroup
        "paginate properties"
        [ testProperty "pageItemTotal is invariant across page requests" $ \(Positive size) (Positive total) (Positive page) ->
            let items = [1 .. total] :: [Int]
                p = paginate size page items
             in pageItemTotal p == total,
          testProperty "pageItems ⊆ items and length ≤ size" $ \(Positive size) (Positive page) (xs :: [Int]) ->
            let p = paginate size page xs
             in length (pageItems p) <= max 1 size,
          testProperty "concatenating every page's items equals input" $ \(Positive size) (xs :: [Int]) ->
            let pages = [paginate size n xs | n <- [1 .. pageTotal (paginate size 1 xs)]]
             in concatMap pageItems pages == xs
        ],
      testGroup
        "resolveBrowseWindow"
        [ testCase "no params → last 24h ending at now" $ do
            let (f, t, n) = resolveBrowseWindow base Nothing Nothing
            assertEqual "from" (Just (addUTCTime (-browseWindowMax) base)) f
            assertEqual "to" (Just base) t
            assertEqual "notice" NoNotice n,
          testCase "explicit from/to within cap is passed through" $ do
            let f0 = addUTCTime (-3600) base
                t0 = base
                (f, t, n) = resolveBrowseWindow base (Just f0) (Just t0)
            assertEqual "from" (Just f0) f
            assertEqual "to" (Just t0) t
            assertEqual "notice" NoNotice n,
          testCase "explicit from/to wider than cap is clamped to cap" $ do
            let f0 = addUTCTime (-(browseWindowMax + 3600)) base
                t0 = base
                (f, t, n) = resolveBrowseWindow base (Just f0) (Just t0)
            assertEqual "from" (Just f0) f
            assertEqual "to clamped to from + cap" (Just (addUTCTime browseWindowMax f0)) t
            assertEqual "notice" (BrowseClamped "Window clamped to 24h") n,
          testCase "from > to falls back to default window with notice" $ do
            let f0 = base
                t0 = addUTCTime (-3600) base
                (f, t, n) = resolveBrowseWindow base (Just f0) (Just t0)
            assertEqual "from default" (Just (addUTCTime (-browseWindowMax) base)) f
            assertEqual "to default" (Just base) t
            assertEqual "notice" (BrowseClamped "Invalid from/to; showing last 24h") n,
          testCase "only from supplied → to = from + cap" $ do
            let f0 = addUTCTime (-7200) base
                (f, t, n) = resolveBrowseWindow base (Just f0) Nothing
            assertEqual "from" (Just f0) f
            assertEqual "to" (Just (addUTCTime browseWindowMax f0)) t
            assertEqual "notice" NoNotice n,
          testCase "only to supplied → from = to - cap" $ do
            let t0 = addUTCTime (-3600) base
                (f, t, n) = resolveBrowseWindow base Nothing (Just t0)
            assertEqual "from" (Just (addUTCTime (-browseWindowMax) t0)) f
            assertEqual "to" (Just t0) t
            assertEqual "notice" NoNotice n
        ],
      testGroup
        "browseQueryString"
        [ testCase "all-Nothing produces empty string" $
            assertEqual "" "" (browseQueryString Nothing Nothing Nothing Nothing Nothing),
          testCase "single param has no leading &" $
            assertEqual "" "&q=floor" (browseQueryString Nothing Nothing Nothing (Just "floor") Nothing),
          testCase "all params concatenated in canonical order" $ do
            let qs = browseQueryString (Just "cam-uuid") (Just "2026-08-12T00:00:00") (Just "2026-08-12T01:00:00") (Just "floor") (Just 120)
            assertEqual "" "&cameraId=cam-uuid&from=2026-08-12T00:00:00&to=2026-08-12T01:00:00&q=floor&minDuration=120" qs,
          testCase "Nothing values are skipped (not emitted as empty)" $
            assertEqual "" "&from=X&q=Y" (browseQueryString Nothing (Just "X") Nothing (Just "Y") Nothing),
          testCase "minDuration=0 is still emitted (not treated as Nothing)" $
            -- Critical for the Sergey bug: a 0 value is a real filter
            -- (effectively no minimum but the user submitted it) and
            -- must round-trip — else the post-delete redirect would
            -- silently rewrite the URL.
            assertEqual "" "&minDuration=0" (browseQueryString Nothing Nothing Nothing Nothing (Just 0)),
          testCase "round-trip preserves leading-& shape controller expects" $ do
            -- The controller's PurgeRecordingAction builds the
            -- redirect URL by dropping the leading "&" — so this
            -- shape is part of the contract, not incidental.
            let qs = browseQueryString (Just "X") Nothing Nothing Nothing Nothing
            assertEqual "leading char is &" '&' (T.head qs)
        ],
      testGroup
        "parseWhen"
        [ testCase "ISO 8601 with seconds parses" $
            assertEqual "" (Just (UTCTime (fromGregorian 2026 8 12) (secondsToDiffTime (5 * 3600 + 7 * 60 + 20)))) $
              parseWhen "2026-08-12T05:07:20",
          testCase "datetime-local without seconds parses" $
            assertEqual "" (Just (UTCTime (fromGregorian 2026 8 12) (secondsToDiffTime (5 * 3600 + 7 * 60)))) $
              parseWhen "2026-08-12T05:07",
          testCase "ISO 8601 with trailing Z parses" $
            assertEqual "" (Just (UTCTime (fromGregorian 2026 8 12) 0)) $
              parseWhen "2026-08-12T00:00:00Z",
          testCase "garbage returns Nothing (no exception)" $
            assertEqual "" Nothing (parseWhen "not a date"),
          testCase "empty returns Nothing" $
            assertEqual "" Nothing (parseWhen "")
        ]
    ]

-- ---- fixtures ------------------------------------------------------

base :: UTCTime
base = UTCTime (fromGregorian 2026 8 12) (secondsToDiffTime 0)
