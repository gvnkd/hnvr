{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.BasePath".
module Hnvr.Core.BasePathSpec (tests) where

import Hnvr.Core.BasePath
  ( basePathSegments,
    normalizeBasePath,
    splitBaseUrl,
    stripBasePathPrefix,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.BasePath"
    [ testGroup
        "splitBaseUrl"
        [ testCase "no path" $
            splitBaseUrl "https://nvr.example.com"
              @?= ("https://nvr.example.com", ""),
          testCase "root path only" $
            splitBaseUrl "https://nvr.example.com/"
              @?= ("https://nvr.example.com", ""),
          testCase "single-segment prefix" $
            splitBaseUrl "https://nvr.example.com/admin"
              @?= ("https://nvr.example.com/admin", "/admin"),
          testCase "trailing slash dropped from both parts" $
            splitBaseUrl "https://nvr.example.com/admin/"
              @?= ("https://nvr.example.com/admin", "/admin"),
          testCase "multi-segment prefix" $
            splitBaseUrl "https://nvr.example.com/nvr/admin"
              @?= ("https://nvr.example.com/nvr/admin", "/nvr/admin"),
          testCase "port preserved" $
            splitBaseUrl "http://10.0.0.5:18010/admin"
              @?= ("http://10.0.0.5:18010/admin", "/admin"),
          testCase "scheme-less authority" $
            splitBaseUrl "localhost:18010" @?= ("localhost:18010", "")
        ],
      testGroup
        "normalizeBasePath"
        [ testCase "empty" $ normalizeBasePath "" @?= "",
          testCase "root" $ normalizeBasePath "/" @?= "",
          testCase "slashes collapsed" $ normalizeBasePath "/admin/" @?= "/admin",
          testCase "bare word" $ normalizeBasePath "admin" @?= "/admin"
        ],
      testGroup
        "stripBasePathPrefix"
        [ testCase "empty prefix matches everything" $
            stripBasePathPrefix "" ["Roles"] @?= Just ["Roles"],
          testCase "prefix root maps to app root" $
            stripBasePathPrefix "/admin" ["admin"] @?= Just [],
          testCase "strips one segment" $
            stripBasePathPrefix "/admin" ["admin", "Roles"] @?= Just ["Roles"],
          testCase "multi-segment prefix" $
            stripBasePathPrefix "/nvr/admin" ["nvr", "admin", "Roles"]
              @?= Just ["Roles"],
          testCase "string-prefix but not segment-prefix does not match" $
            stripBasePathPrefix "/admin" ["adminfoo"] @?= Nothing,
          testCase "unrelated path does not match" $
            stripBasePathPrefix "/admin" ["Roles"] @?= Nothing,
          testCase "shorter path does not match" $
            stripBasePathPrefix "/nvr/admin" ["nvr"] @?= Nothing,
          testCase "segments round-trip" $
            basePathSegments "/nvr/admin" @?= ["nvr", "admin"]
        ]
    ]
