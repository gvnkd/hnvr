module Main (main) where

import qualified Hnvr.Core.ArchiveBrowserSpec as ArchiveBrowserSpec
import qualified Hnvr.Core.AssignmentSpec as AssignmentSpec
import qualified Hnvr.Core.CryptoSpec as CryptoSpec
import qualified Hnvr.Core.GeometrySpec as GeometrySpec
import qualified Hnvr.Core.IdSpec as IdSpec
import qualified Hnvr.Core.PlaylistSpec as PlaylistSpec
import qualified Hnvr.Core.RecordingSpec as RecordingSpec
import qualified Hnvr.Core.SegmentSpec as SegmentSpec
import qualified Hnvr.Core.TimeSpec as TimeSpec
import qualified Hnvr.Core.WhepSpec as WhepSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "hnvr-core"
      [ ArchiveBrowserSpec.tests,
        AssignmentSpec.tests,
        CryptoSpec.tests,
        GeometrySpec.tests,
        IdSpec.tests,
        PlaylistSpec.tests,
        RecordingSpec.tests,
        SegmentSpec.tests,
        TimeSpec.tests,
        WhepSpec.tests
      ]
