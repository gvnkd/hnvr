module Main (main) where

import qualified Hnvr.Nats.BusSpec as BusSpec
import qualified Hnvr.Nats.SubjectsSpec as SubjectsSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "hnvr-nats"
      [ SubjectsSpec.tests,
        BusSpec.tests
      ]
