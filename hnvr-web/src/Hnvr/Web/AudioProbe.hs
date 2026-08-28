{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | IO runner for the audio-rate probe ("Hnvr.Core.AudioProbe").
--
-- Two ffprobe passes against the camera's MediaMTX relay path:
--
--   1. codec + declared rate — cheap, ffprobe exits by itself;
--   2. (only for fixed-clock codecs) packet sizes + arrival times,
--      read for a bounded window and killed — ffprobe never exits on
--      a live source.
--
-- Everything time-critical is monotonic-clock based and everything
-- fallible returns 'Nothing' rather than throwing: a probe failure
-- must degrade to the old behaviour (no @asetrate@ retag), never
-- block a recording start or a config sync.
module Hnvr.Web.AudioProbe
  ( probeCameraAudio,
  )
where

import Control.Exception (SomeException, bracket, try)
import qualified Data.ByteString.Lazy as BL
import qualified Data.Char as Char
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import GHC.Clock (getMonotonicTimeNSec)
import Hnvr.Core.AudioProbe
  ( ProbedAudio (..),
    bitsPerSample,
    codecProbeArgs,
    isFixedClockCodec,
    packetProbeArgs,
    parseCodecFields,
    quirkAsetrateHz,
    trueRateHz,
  )
import System.IO (hGetLine)
import System.Process.Typed
import System.Timeout (timeout)

-- | Seconds of packets discarded before measuring: the RTSP setup
-- and the camera's connect burst land here.
warmupSecs :: Double
warmupSecs = 1.0

-- | Measurement window. 6 s of G.711 at 16 kHz is ~180 packets —
-- comfortably past the >= 10-packet floor in 'trueRateHz'.
windowSecs :: Double
windowSecs = 6.0

-- | Probe a relay URL (@rtsp://host:8554/<slug>@). 'Nothing' = no
-- audio track at all, or the probe could not complete.
probeCameraAudio :: Text -> IO (Maybe ProbedAudio)
probeCameraAudio url = do
  mMeta <- probeCodec url
  case mMeta of
    Nothing -> pure Nothing
    Just (codec, declaredHz)
      -- Non-G.711-family codecs carry their true rate in the SDP;
      -- retagging them would corrupt pitch.
      | not (isFixedClockCodec codec) -> pure (Just (ProbedAudio codec declaredHz Nothing))
      | otherwise -> do
          pts <- collectPackets url
          let mRate = case bitsPerSample codec of
                Just bits -> trueRateHz bits pts >>= quirkAsetrateHz declaredHz
                Nothing -> Nothing
          pure (Just (ProbedAudio codec declaredHz mRate))

-- | First ffprobe pass. 10 s hard cap covers the sourceOnDemand
-- camera pull that our RTSP request may trigger.
probeCodec :: Text -> IO (Maybe (Text, Int))
probeCodec url =
  fromMaybe Nothing
    <$> timeout
      (10 * 1000000)
      ( do
          (_, out) <- readProcessStdout (proc "ffprobe" (codecProbeArgs url))
          pure $ case map (parseCodecFields . T.strip) (T.lines (decode out)) of
            (Just p : _) -> Just p
            _ -> Nothing
      )
  where
    decode = TE.decodeUtf8 . BL.toStrict

-- | Second ffprobe pass: stream @<pts>,<size>@ lines, timestamp each
-- arrival with the monotonic clock, stop after the window. The
-- process is killed by 'stopProcess' under 'bracket'; EOF (camera
-- went away) ends the loop early with whatever was collected. A hard
-- 'timeout' guards against sources that stall mid-DESCRIBE.
collectPackets :: Text -> IO [(Double, Int)]
collectPackets url =
  bracket
    (startProcess (setStdout createPipe (proc "ffprobe" (packetProbeArgs url))))
    ( \p -> do
        _ <- try (stopProcess p) :: IO (Either SomeException ())
        pure ()
    )
    $ \p -> do
      let h = getStdout p
      t0 <- getMonotonicTimeNSec
      pts <-
        fromMaybe []
          <$> timeout
            (round ((warmupSecs + windowSecs + 8) * 1000000))
            (loop h t0 [])
      pure (reverse pts)
  where
    loop h t0 acc = do
      mLine <- try (hGetLine h) :: IO (Either SomeException String)
      case mLine of
        Left _ -> pure acc
        Right l -> do
          now <- getMonotonicTimeNSec
          let dt = fromIntegral (now - t0) / 1e9 :: Double
          if dt > warmupSecs + windowSecs
            then pure acc
            else case parsePacket l of
              Nothing -> loop h t0 acc
              Just sz
                | dt < warmupSecs -> loop h t0 acc
                | otherwise -> loop h t0 ((dt, sz) : acc)

-- | @<pts_time>,<size>@ → size. ffprobe csv emits the pts first; we
-- deliberately ignore it — media-time math reproduces the declared
-- rate, only arrival time carries the true one.
parsePacket :: String -> Maybe Int
parsePacket l =
  case break (== ',') l of
    (a, ',' : b)
      | not (null b),
        all Char.isDigit b ->
          Just (read b)
      | otherwise -> Nothing
    _ -> Nothing
