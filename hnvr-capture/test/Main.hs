module Main (main) where

import qualified Hnvr.Capture.FfmpegSpec as FfmpegSpec
import qualified Hnvr.Capture.Fmp4Spec as Fmp4Spec
import qualified Hnvr.Capture.FrameSourceSpec as FrameSourceSpec
import qualified Hnvr.Capture.RingBufferSpec as RingBufferSpec
import qualified Hnvr.Capture.SpoolDrainerSpec as SpoolDrainerSpec
import qualified Hnvr.Capture.WorkerSpec as WorkerSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "hnvr-capture"
      [ Fmp4Spec.tests,
        FfmpegSpec.tests,
        FrameSourceSpec.tests,
        RingBufferSpec.tests,
        SpoolDrainerSpec.tests,
        WorkerSpec.tests
      ]
