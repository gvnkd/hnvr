{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.Whep".
--
-- Pins the path-translation behaviour that was a historical bug source
-- (pitfall #62: naive @"/" <> rest <> "/whep"@ append mangled session
-- callbacks). The fix splits the path at the first @/@ after the slug
-- so @/whep@ lands directly after the slug — every test below asserts
-- a case from that bug report.
module Hnvr.Core.WhepSpec (tests) where

import qualified Data.ByteString as BS
import Hnvr.Core.Whep (translateBack, translatePath)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Whep"
    [ testGroup
        "translatePath (/whep/<slug> → /<slug>-live/whep)"
        [ testCase "plain slug (POST offer)" $
            assertEqual
              "no session"
              "/cam-197-live/whep"
              (translatePath "/whep/cam-197"),
          testCase "slug + session id (PATCH/DELETE)" $
            -- This is the case pitfall #62 fixed: the naive append
            -- produced "/cam-197/session/abc/whep" (mediamtx 404).
            assertEqual
              "with session"
              "/cam-197-live/whep/session/abc"
              (translatePath "/whep/cam-197/session/abc"),
          testCase "multi-segment slug suffix stays attached" $
            assertEqual
              "deep suffix"
              "/cam-197-live/whep/session/abc/ice-restart"
              (translatePath "/whep/cam-197/session/abc/ice-restart"),
          testCase "slug with embedded slash is preserved as-is" $
            -- Pathological: a slug-like token containing a slash. We
            -- split at the FIRST slash so anything after is suffix.
            assertEqual
              "split at first slash"
              "/a-live/whep/b/c/d"
              (translatePath "/whep/a/b/c/d")
        ],
      testGroup
        "translateBack (/<slug>-live/whep → /whep/<slug>)"
        [ testCase "path-only Location" $
            assertEqual
              "path only"
              "/whep/cam-197/session/abc"
              (translateBack "/cam-197-live/whep/session/abc"),
          testCase "absolute http URL strips scheme + host" $
            assertEqual
              "http absolute"
              "/whep/cam-197/session/abc"
              (translateBack "http://127.0.0.1:8889/cam-197-live/whep/session/abc"),
          testCase "absolute https URL strips scheme + host" $
            assertEqual
              "https absolute"
              "/whep/cam-197/session/abc"
              (translateBack "https://leader.example/cam-197-live/whep/session/abc"),
          testCase "no /whep in path passes through unchanged" $
            assertEqual
              "passthrough"
              "/something/else"
              (translateBack "/something/else")
        ],
      testGroup
        "round-trip (translatePath and translateBack are inverses)"
        [ testCase "translateBack . translatePath == id (browser form)" $
            -- Browser sees paths like /whep/<slug>/session/<id>. Forward
            -- then back should round-trip.
            let p = "/whep/cam-197/session/abc"
             in assertEqual "browser form round-trip" p (translateBack (translatePath p)),
          testCase "translatePath . translateBack == id (mediamtx form)" $
            -- MediaMTX emits Location headers in its own form
            -- (/<slug>-live/whep/session/<id>). Back then forward should
            -- round-trip.
            let m = "/cam-197-live/whep/session/abc"
             in assertEqual "mediamtx form round-trip" m (translatePath (translateBack m))
        ]
    ]
