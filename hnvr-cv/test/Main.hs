module Main (main) where

import qualified Hnvr.Cv.AnalyzerRunnerSpec as AnalyzerRunnerSpec
import qualified Hnvr.Cv.AnalyzerSpec as AnalyzerSpec
import qualified Hnvr.Cv.DebugRenderSpec as DebugRenderSpec
import qualified Hnvr.Cv.DecodeSpec as DecodeSpec
import qualified Hnvr.Cv.OnnxRuntimeSpec as OnnxRuntimeSpec
import qualified Hnvr.Cv.PreprocessSpec as PreprocessSpec
import qualified Hnvr.Cv.RulesSpec as RulesSpec
import qualified Hnvr.Cv.TrackerSpec as TrackerSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "hnvr-cv"
      [ AnalyzerRunnerSpec.tests,
        AnalyzerSpec.tests,
        DebugRenderSpec.tests,
        DecodeSpec.tests,
        OnnxRuntimeSpec.tests,
        PreprocessSpec.tests,
        RulesSpec.tests,
        TrackerSpec.tests
      ]
