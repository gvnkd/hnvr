{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.SessionCookie".
module Hnvr.Core.SessionCookieSpec (tests) where

import Hnvr.Core.SessionCookie
  ( rewriteRequestCookie,
    rewriteSetCookie,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.SessionCookie"
    [ testGroup
        "rewriteRequestCookie"
        [ testCase "own cookie becomes SESSION" $
            rewriteRequestCookie "hnvr_admin" "hnvr_admin=abc123"
              @?= "SESSION=abc123",
          testCase "foreign SESSION is dropped" $
            rewriteRequestCookie "hnvr_admin" "SESSION=leader-session"
              @?= "",
          testCase "own wins over foreign SESSION" $
            rewriteRequestCookie "hnvr" "SESSION=old; hnvr=mine"
              @?= "SESSION=mine",
          testCase "unrelated cookies are kept" $
            rewriteRequestCookie "hnvr" "theme=dark; hnvr=s1; other=x"
              @?= "theme=dark; other=x; SESSION=s1",
          testCase "value with = padding survives" $
            rewriteRequestCookie "hnvr" "hnvr=YWJjZA=="
              @?= "SESSION=YWJjZA==",
          testCase "space after semicolon tolerated" $
            rewriteRequestCookie "hnvr" "a=1; hnvr=s2; b=2"
              @?= "a=1; b=2; SESSION=s2",
          testCase "no own cookie, no SESSION" $
            rewriteRequestCookie "hnvr" "a=1; b=2" @?= "a=1; b=2"
        ],
      testGroup
        "rewriteSetCookie"
        [ testCase "SESSION renamed, flags kept" $
            rewriteSetCookie "hnvr_admin" "SESSION=v1; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax"
              @?= Just "hnvr_admin=v1; Path=/; Max-Age=2592000; HttpOnly; SameSite=Lax",
          testCase "deletion (expired) renamed" $
            rewriteSetCookie "hnvr" "SESSION=; Path=/; Expires=Thu, 01-Jan-1970 00:00:00 GMT"
              @?= Just "hnvr=; Path=/; Expires=Thu, 01-Jan-1970 00:00:00 GMT",
          testCase "other cookies untouched" $
            rewriteSetCookie "hnvr" "other=v; Path=/" @?= Nothing,
          testCase "SESSIONX is not SESSION" $
            rewriteSetCookie "hnvr" "SESSIONX=v; Path=/" @?= Nothing
        ]
    ]
