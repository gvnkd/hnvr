{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Debug overlay rendering for the Phase 3 @/debug/<slug>@ view.
--
-- Draws track boxes onto the frame's RGB pixels and PNG-encodes via
-- JuicyPixels. Roadmap says "MJPEG over WebSocket" — we deviate
-- deliberately: multipart/x-mixed-replace with PNG parts works with a
-- plain @<img>@ tag (no JS). JuicyPixels gained a JPEG encoder in
-- 3.2.4 ('encodeJpegAtQuality'), which the periodic snapshot store
-- (design_docs/12-timeline-archive.md) uses — PNG remains for the
-- debug view and event thumbnails.
--
-- Track IDs are color-coded (deterministic palette by id) rather than
-- text-rendered — no font dependency. The HTML page lists the same
-- colors so ids are readable.
module Hnvr.Cv.DebugRender
  ( trackColor,
    trackColorCss,
    renderDebugPng,
    renderJpeg,
  )
where

import Codec.Picture (Image (..), PixelRGB8 (..), PixelYCbCr8, encodeJpegAtQuality, encodePng)
import Codec.Picture.Types (convertImage)
import Control.Monad (forM_)
import Control.Monad.ST (ST, runST)
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector.Storable as VS
import qualified Data.Vector.Storable.Mutable as MV
import Data.Word (Word8)
import Hnvr.Core.Frame (Frame (..))
import Hnvr.Core.Geometry (Box (..))
import Hnvr.Cv.Tracker.Sort (Track (..), TrackId (..))

-- | Deterministic per-track color. Bright palette, cycled by id;
-- neighboring ids land on visually distinct entries.
trackColor :: TrackId -> PixelRGB8
trackColor (TrackId n) = palette !! fromIntegral ((n * 5) `mod` 8)
  where
    palette =
      [ PixelRGB8 255 56 56, -- red
        PixelRGB8 56 255 56, -- green
        PixelRGB8 56 128 255, -- blue
        PixelRGB8 255 255 56, -- yellow
        PixelRGB8 255 56 255, -- magenta
        PixelRGB8 56 255 255, -- cyan
        PixelRGB8 255 158 56, -- orange
        PixelRGB8 178 102 255 -- purple
      ]

-- | 'trackColor' as a CSS @rgb(r,g,b)@ string — the debug HTML legend
-- uses the same colors as the overlay boxes.
trackColorCss :: TrackId -> Text
trackColorCss tid =
  let PixelRGB8 r g b = trackColor tid
   in "rgb(" <> T.pack (show r) <> "," <> T.pack (show g) <> "," <> T.pack (show b) <> ")"

-- | Frame with track boxes drawn (2 px outlines, clamped to frame
-- bounds), PNG-encoded.
renderDebugPng :: Frame -> [Track] -> BL.ByteString
renderDebugPng Frame {frameWidth = w, frameHeight = h, frameRgb = rgb} tracks = runST $ do
  mv <- VS.thaw rgb
  forM_ tracks $ \t -> drawBox mv w h (trackColor (tId t)) (tBox t)
  frozen <- VS.freeze mv
  let img :: Image PixelRGB8
      img = Image {imageWidth = w, imageHeight = h, imageData = frozen}
  pure $ encodePng img

-- | Bare frame (no overlay), JPEG-encoded at the given quality
-- (0-100). Used by the periodic snapshot store — ~10x smaller than
-- PNG at analysis resolution, and snapshots are written once per
-- 'Hnvr.Core.CameraSnapshot.csSnapshotIntervalSec', not per event.
renderJpeg :: Int -> Frame -> BL.ByteString
renderJpeg quality Frame {frameWidth = w, frameHeight = h, frameRgb = rgb} =
  let img :: Image PixelRGB8
      img = Image {imageWidth = w, imageHeight = h, imageData = rgb}
      ycbcr :: Image PixelYCbCr8
      ycbcr = convertImage img
   in encodeJpegAtQuality (fromIntegral (max 0 (min 100 quality))) ycbcr

-- | 2 px rectangle outline, edges clamped inside the frame.
drawBox :: MV.MVector s Word8 -> Int -> Int -> PixelRGB8 -> Box Float -> ST s ()
drawBox mv w h (PixelRGB8 r g b) Box {bxX = x, bxY = y, bxW = bw, bxH = bh} = do
  let x0 = clampX (round x)
      y0 = clampY (round y)
      x1 = clampX (round (x + bw) - 1)
      y1 = clampY (round (y + bh) - 1)
  forM_ [x0 .. x1] $ \px ->
    forM_ [0, 1] $ \t -> do
      setPx px (y0 + t)
      setPx px (y1 - t)
  forM_ [y0 .. y1] $ \py ->
    forM_ [0, 1] $ \t -> do
      setPx (x0 + t) py
      setPx (x1 - t) py
  where
    clampX = max 0 . min (w - 1)
    clampY = max 0 . min (h - 1)
    setPx px py = do
      let i = (py * w + px) * 3
      MV.write mv i r
      MV.write mv (i + 1) g
      MV.write mv (i + 2) b
