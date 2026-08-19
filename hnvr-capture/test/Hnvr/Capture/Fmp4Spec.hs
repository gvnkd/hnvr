{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Tests for "Hnvr.Capture.Fmp4".
--
-- Anchor property: /chunk-boundary invariance/. The Fmp4 parser is
-- documented in its Haddock as a pure Mealy machine — feeding the same
-- bytes in arbitrary chunkings must yield the same 'Fragment' sequence.
module Hnvr.Capture.Fmp4Spec (tests) where

import Data.Bits (shiftR)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import Data.Maybe (maybeToList)
import Data.Word (Word32, Word64, Word8)
import Hnvr.Capture.Fmp4 (Fragment (..), feed, finish, initial)
import Test.QuickCheck
  ( Arbitrary (arbitrary),
    Gen,
    Property,
    choose,
    counterexample,
    elements,
    forAll,
    vectorOf,
    (===),
  )
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, testCase)
import Test.Tasty.QuickCheck (testProperty)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Capture.Fmp4"
    [ testGroup
        "chunk-boundary invariance"
        [ testProperty
            "any chunking yields the same fragments as one-shot"
            prop_chunkBoundaryInvariance,
          testProperty
            "1-byte chunking yields the same fragments as one-shot"
            prop_oneByteChunking
        ],
      testProperty
        "tfdt extraction matches first tfdt in moof"
        prop_tfdtExtraction,
      testGroup
        "specific cases"
        [ testCase "empty stream → no fragments" $
            assertEqual
              "feed [] on empty"
              []
              (feedAll ""),
          testCase "init only (no moof) → no fragments; finish = Nothing" $ do
            let s = box "ftyp" "abcd" <> box "moov" "xyz"
            assertEqual "feed" [] (feedAll s)
            assertEqual "finish" Nothing (finishAll s),
          testCase "single moof+mdat → one MediaFragment" $ do
            let s = renderStream (SyntheticStream [] [(42, "hello")])
            assertEqual
              "frags"
              [MediaFragment 42 False (moofBox 42 <> mdatBox "hello")]
              (feedAll s),
          testCase "two-traf moof → hasAudio=True" $ do
            let s = box "moof" (trafBox 7 <> trafBox 8) <> mdatBox "x"
            assertEqual
              "frags"
              [MediaFragment 7 True s]
              (feedAll s),
          testCase "init + two frags → InitFragment then two MediaFragments" $ do
            let initBs = box "ftyp" "abcd"
                s = renderStream (SyntheticStream [initBs] [(1, "a"), (2, "bb")])
            assertEqual
              "frags"
              [ InitFragment initBs,
                MediaFragment 1 False (moofBox 1 <> mdatBox "a"),
                MediaFragment 2 False (moofBox 2 <> mdatBox "bb")
              ]
              (feedAll s),
          testCase "truncated box header → no fragment until complete" $ do
            let full = moofBox 7
                -- Drop last byte: parser waits for the full box.
                truncated = B.take (B.length full - 1) full
                (frags, _) = feed initial truncated
            assertEqual "partial feed" [] frags
        ]
    ]

-- ---- chunk-boundary properties -------------------------------------

prop_chunkBoundaryInvariance :: SyntheticStream -> Property
prop_chunkBoundaryInvariance ss =
  let bytes = renderStream ss
      expected = feedAll bytes
   in forAll (arbitraryChunking bytes) $ \chunks ->
        feedChunks chunks === expected

prop_oneByteChunking :: SyntheticStream -> Property
prop_oneByteChunking ss =
  let bytes = renderStream ss
      expected = feedAll bytes
      chunks = map B.singleton (B.unpack bytes)
   in feedChunks chunks === expected

-- | The first tfdt value in the moof is surfaced as the MediaFragment's
-- 'Word64' field.
prop_tfdtExtraction :: Word64 -> Property
prop_tfdtExtraction ts =
  let s = renderStream (SyntheticStream [] [(ts, "p")])
   in case feedAll s of
        [MediaFragment gotTfdt _ _] -> gotTfdt === ts
        other ->
          counterexample ("unexpected frags: " <> show other) False

-- ---- helpers: feed the parser in different ways --------------------

feedAll :: ByteString -> [Fragment]
feedAll bytes =
  let (frags, st) = feed initial bytes
   in frags ++ maybeToList (finish st)

finishAll :: ByteString -> Maybe Fragment
finishAll bytes = finish (snd (feed initial bytes))

feedChunks :: [ByteString] -> [Fragment]
feedChunks chunks =
  let (frags, st) = foldl' step ([], initial) chunks
      step (acc, s) c = let (newFs, s') = feed s c in (acc ++ newFs, s')
   in frags ++ maybeToList (finish st)

-- ---- synthetic fMP4 stream generator -------------------------------

-- | A synthetic stream: some pre-moof "init" bytes plus a list of
-- (tfdt, mdat payload) pairs. Each pair renders as a moof+mdat box pair.
data SyntheticStream = SyntheticStream
  { ssInit :: [ByteString],
    ssFrags :: [(Word64, ByteString)]
  }
  deriving stock (Eq, Show)

renderStream :: SyntheticStream -> ByteString
renderStream (SyntheticStream initBs frags) =
  B.concat initBs <> B.concat (map renderFrag frags)
  where
    renderFrag (tfdt, payload) = moofBox tfdt <> mdatBox payload

moofBox :: Word64 -> ByteString
moofBox tfdt = box "moof" (trafBox tfdt)

-- | One traf child (tfhd + tfdt) as it appears inside a moof.
trafBox :: Word64 -> ByteString
trafBox tfdt = box "traf" (tfhdBox <> tfdtBox tfdt)

tfhdBox :: ByteString
tfhdBox = box "tfhd" (B.replicate 4 0x00)

-- | tfdt box with version=1 (64-bit baseMediaDecodeTime).
tfdtBox :: Word64 -> ByteString
tfdtBox ts =
  box "tfdt" $
    B.singleton 0x01 -- version 1
      <> B.replicate 3 0x00 -- 3-byte flags
      <> encodeBE64 ts

mdatBox :: ByteString -> ByteString
mdatBox = box "mdat"

-- | Standard ISO-BMFF box: 4-byte big-endian size + 4-byte type + payload.
box :: ByteString -> ByteString -> ByteString
box typ payload =
  encodeBE32 (fromIntegral (8 + B.length payload)) <> typ <> payload

encodeBE32 :: Word32 -> ByteString
encodeBE32 w = B.pack [fromIntegral (w `shiftR` s) | s <- [24, 16, 8, 0]]

encodeBE64 :: Word64 -> ByteString
encodeBE64 w =
  B.pack [fromIntegral (w `shiftR` s) | s <- [56, 48, 40, 32, 24, 16, 8, 0]]

-- ---- QuickCheck instance -------------------------------------------

instance Arbitrary SyntheticStream where
  arbitrary = do
    nInit <- choose (0, 3)
    nFrags <- choose (0, 5)
    initBs <- vectorOf nInit arbitraryInitBox
    frags <- vectorOf nFrags ((,) <$> arbitrary <*> smallBytes)
    pure (SyntheticStream initBs frags)
    where
      arbitraryInitBox = do
        typ <- elements ["ftyp", "moov", "free", "skip", "styp"]
        box typ <$> smallBytes
      smallBytes = do
        n <- choose (0, 50)
        B.pack <$> vectorOf n (arbitrary :: Gen Word8)

-- | Random chunking of a ByteString (always non-empty chunks; total =
-- the input).
arbitraryChunking :: ByteString -> Gen [ByteString]
arbitraryChunking bytes
  | B.null bytes = pure []
  | otherwise = do
      -- Bias toward small chunks so we hit boundary cases often.
      maxSize <- elements [1, 1, 1, 2, 3, 5, 8, 13]
      n <- choose (1, maxSize)
      let (chunk, rest) = B.splitAt n bytes
      restChunks <- arbitraryChunking rest
      pure (chunk : restChunks)
