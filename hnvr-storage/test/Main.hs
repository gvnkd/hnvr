module Main (main) where

import qualified Hnvr.Storage.S3Spec as S3Spec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "hnvr-storage"
      [ S3Spec.tests
      ]
