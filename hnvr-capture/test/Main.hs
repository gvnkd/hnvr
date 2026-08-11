module Main (main) where

import qualified Hnvr.Capture.Fmp4Spec as Fmp4Spec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "hnvr-capture"
      [ Fmp4Spec.tests
      ]
