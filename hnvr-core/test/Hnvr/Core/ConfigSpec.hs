{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.Config" — pure YAML parsing of the app config
-- file. The loader itself ('loadAppConfig') is a thin file-exists +
-- readFile wrapper and is covered by consumers.
module Hnvr.Core.ConfigSpec (tests) where

import Data.ByteString (ByteString)
import Data.Either (isLeft)
import Hnvr.Core.Config
  ( AppConfig (..),
    S3Section (..),
    parseAppConfig,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Config"
    [ testCase "parses a full s3 section" $
        parseAppConfig fullDoc @?= Right (AppConfig (Just fullSection)),
      testCase "optional fields default to Nothing" $
        parseAppConfig minimalDoc
          @?= Right
            ( AppConfig
                ( Just
                    fullSection
                      { ssPublicEndpoint = Nothing,
                        ssRoAccessKey = Nothing,
                        ssRoSecretKey = Nothing
                      }
                )
            ),
      testCase "unknown top-level keys are ignored" $
        parseAppConfig ("future_section:\n  foo: 1\n" <> minimalDoc)
          @?= Right
            ( AppConfig
                ( Just
                    fullSection
                      { ssPublicEndpoint = Nothing,
                        ssRoAccessKey = Nothing,
                        ssRoSecretKey = Nothing
                      }
                )
            ),
      testCase "no s3 section → Nothing" $
        parseAppConfig "nats:\n  uri: nats://x\n" @?= Right (AppConfig Nothing),
      testCase "missing required field is an error" $
        isLeft (parseAppConfig "s3:\n  endpoint: http://x\n") @?= True,
      testCase "malformed yaml is an error" $
        isLeft (parseAppConfig "s3: [unclosed") @?= True
    ]

fullDoc :: ByteString
fullDoc =
  "s3:\n\
  \  endpoint: \"http://192.168.0.254:8333\"\n\
  \  public_endpoint: \"http://192.168.0.254:8333\"\n\
  \  bucket: \"hnvr\"\n\
  \  access_key: \"AK\"\n\
  \  secret_key: \"SK\"\n\
  \  ro_access_key: \"ROAK\"\n\
  \  ro_secret_key: \"ROSK\"\n"

minimalDoc :: ByteString
minimalDoc =
  "s3:\n\
  \  endpoint: \"http://192.168.0.254:8333\"\n\
  \  bucket: \"hnvr\"\n\
  \  access_key: \"AK\"\n\
  \  secret_key: \"SK\"\n"

fullSection :: S3Section
fullSection =
  S3Section
    { ssEndpoint = "http://192.168.0.254:8333",
      ssAccessKey = "AK",
      ssSecretKey = "SK",
      ssBucket = "hnvr",
      ssPublicEndpoint = Just "http://192.168.0.254:8333",
      ssRoAccessKey = Just "ROAK",
      ssRoSecretKey = Just "ROSK"
    }
