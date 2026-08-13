{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.Metrics" — the pure Prometheus text renderer.
module Hnvr.Core.MetricsSpec (tests) where

import Hnvr.Core.Metrics
  ( DistStats (..),
    MetricSample (..),
    renderPrometheus,
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Metrics"
    [ testGroup
        "renderPrometheus"
        [ testCase "counter renders name + value" $
            renderPrometheus [("hnvr_frames_decoded_total{camera=\"a\"}", SCounter 42)]
              @?= "hnvr_frames_decoded_total{camera=\"a\"} 42\n",
          testCase "gauge renders name + value" $
            renderPrometheus [("hnvr_gpu_memory_used_bytes", SGauge 1024)]
              @?= "hnvr_gpu_memory_used_bytes 1024\n",
          testCase "distribution expands to count/sum" $
            renderPrometheus [("hnvr_inference_seconds{ep=\"cpu\"}", SDist dist)]
              @?= "hnvr_inference_seconds_count{ep=\"cpu\"} 3\n\
                  \hnvr_inference_seconds_sum{ep=\"cpu\"} 0.6\n",
          testCase "distribution without labels keeps suffix at end" $
            renderPrometheus [("hnvr_inference_seconds", SDist dist)]
              @?= "hnvr_inference_seconds_count 3\n\
                  \hnvr_inference_seconds_sum 0.6\n",
          testCase "samples render in input order, one per line" $
            renderPrometheus
              [ ("b_total", SCounter 1),
                ("a_total", SCounter 2)
              ]
              @?= "b_total 1\na_total 2\n",
          testCase "empty input renders empty" $
            renderPrometheus [] @?= "\n"
        ]
    ]
  where
    dist =
      DistStats
        { dsMean = 0.2,
          dsVariance = 0.03,
          dsCount = 3,
          dsSum = 0.6,
          dsMin = 0.1,
          dsMax = 0.5
        }
