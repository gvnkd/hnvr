module Main (main) where

import qualified Hnvr.Core.ArchiveBrowserSpec as ArchiveBrowserSpec
import qualified Hnvr.Core.AssignmentSpec as AssignmentSpec
import qualified Hnvr.Core.CameraSnapshotSpec as CameraSnapshotSpec
import qualified Hnvr.Core.CameraStatusSpec as CameraStatusSpec
import qualified Hnvr.Core.ClipSpec as ClipSpec
import qualified Hnvr.Core.ConfigSpec as ConfigSpec
import qualified Hnvr.Core.CryptoSpec as CryptoSpec
import qualified Hnvr.Core.DvripSpec as DvripSpec
import qualified Hnvr.Core.EventSpec as EventSpec
import qualified Hnvr.Core.FrameSpec as FrameSpec
import qualified Hnvr.Core.GeometrySpec as GeometrySpec
import qualified Hnvr.Core.HostClaimSpec as HostClaimSpec
import qualified Hnvr.Core.IdSpec as IdSpec
import qualified Hnvr.Core.MetricsSpec as MetricsSpec
import qualified Hnvr.Core.OnvifSpec as OnvifSpec
import qualified Hnvr.Core.PlaylistSpec as PlaylistSpec
import qualified Hnvr.Core.PtzSpec as PtzSpec
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
        CameraSnapshotSpec.tests,
        CameraStatusSpec.tests,
        ClipSpec.tests,
        ConfigSpec.tests,
        CryptoSpec.tests,
        DvripSpec.tests,
        EventSpec.tests,
        FrameSpec.tests,
        GeometrySpec.tests,
        HostClaimSpec.tests,
        IdSpec.tests,
        MetricsSpec.tests,
        OnvifSpec.tests,
        PlaylistSpec.tests,
        PtzSpec.tests,
        RecordingSpec.tests,
        SegmentSpec.tests,
        TimeSpec.tests,
        WhepSpec.tests
      ]
