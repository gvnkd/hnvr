{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Nats.Subjects".
--
-- Pure unit tests covering subject-name construction and the
-- "no two constructors produce the same literal prefix" property.
module Hnvr.Nats.SubjectsSpec (tests) where

import Control.Monad (when)
import Data.Text (Text)
import qualified Data.Text as T
import Hnvr.Nats.Subjects
  ( commandAssign,
    commandControl,
    commandPtz,
    configCameras,
    events,
    health,
    leader,
    ptzStatus,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Nats.Subjects"
    [ testGroup
        "literal constructors"
        [ testCase "events" $
            assertEqual "events stream" "hnvr.events" events,
          testCase "commandAssign" $
            assertEqual
              "assign"
              "hnvr.commands.assign.cam-197"
              (commandAssign "cam-197"),
          testCase "commandControl" $
            assertEqual
              "control"
              "hnvr.commands.control.hnvr-1.cam-197.stop"
              (commandControl "hnvr-1" "cam-197" "stop"),
          testCase "commandPtz" $
            assertEqual
              "ptz"
              "hnvr.commands.ptz.cam-197"
              (commandPtz "cam-197"),
          testCase "health" $
            assertEqual
              "health"
              "hnvr.health.hnvr-2"
              (health "hnvr-2"),
          testCase "configCameras" $
            assertEqual
              "config.cameras"
              "hnvr.config.cameras.cam-197"
              (configCameras "cam-197"),
          testCase "ptzStatus" $
            assertEqual
              "ptz.status"
              "hnvr.ptz.status.cam-197"
              (ptzStatus "cam-197"),
          testCase "leader (KV bucket)" $
            assertEqual "leader" "hnvr.leader" leader
        ],
      testCase "no two prefix families overlap" $ do
        -- Same slug must not accidentally collide across families:
        -- assign vs config vs commands.control all start with
        -- hnvr.commands. vs hnvr.config. — they shouldn't be equal.
        let slug = "cam-1"
        let assignSubj = commandAssign slug
            configSubj = configCameras slug
            ptzCmdSubj = commandPtz slug
            ptzStatSubj = ptzStatus slug
        when (assignSubj == configSubj) $
          assertFailure ("assign == config: " <> show assignSubj)
        when (ptzCmdSubj == ptzStatSubj) $
          assertFailure
            ( "ptz command == ptz status: "
                <> show ptzCmdSubj
            ),
      testCase "all subjects have hnvr. prefix and no trailing dot" $ do
        let allSubjs =
              [ events,
                commandAssign "x",
                commandControl "h" "c" "a",
                commandPtz "x",
                health "h",
                configCameras "x",
                ptzStatus "x",
                leader
              ]
        let check s
              | not (T.isPrefixOf "hnvr." s) =
                  assertFailure ("missing hnvr. prefix: " <> show s)
              | T.isSuffixOf "." s =
                  assertFailure ("trailing dot: " <> show s)
              | otherwise = pure ()
        mapM_ check allSubjs
    ]
