module Main (main) where

import qualified Hnvr.Core.CryptoSpec as CryptoSpec
import qualified Hnvr.Core.GeometrySpec as GeometrySpec
import qualified Hnvr.Core.IdSpec as IdSpec
import qualified Hnvr.Core.SegmentSpec as SegmentSpec
import qualified Hnvr.Core.TimeSpec as TimeSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "hnvr-core"
      [ CryptoSpec.tests,
        GeometrySpec.tests,
        IdSpec.tests,
        SegmentSpec.tests,
        TimeSpec.tests
      ]
