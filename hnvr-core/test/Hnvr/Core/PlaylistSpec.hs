{-# LANGUAGE OverloadedStrings #-}

-- | Tests for "Hnvr.Core.Playlist".
module Hnvr.Core.PlaylistSpec (tests) where

import Data.Text (Text)
import qualified Data.Text as T
import Hnvr.Core.Playlist (renderEmptyPlaylist, renderVodPlaylist)
import Test.QuickCheck (Positive (..), arbitrary, listOf1)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase)
import Test.Tasty.QuickCheck (forAll, testProperty)

tests :: TestTree
tests =
  testGroup
    "Hnvr.Core.Playlist"
    [ testCase "renders header, map, entries, endlist" $ do
        let m3u8 = renderVodPlaylist "https://s3/init.mp4" [(1.0, "u1"), (1.2, "u2")]
            ls = T.lines m3u8
        assertEqual "head" ["#EXTM3U", "#EXT-X-VERSION:6"] (take 2 ls)
        assertBool "target duration" ("#EXT-X-TARGETDURATION:2" `elem` ls)
        assertBool "map" ("#EXT-X-MAP:URI=\"https://s3/init.mp4\"" `elem` ls)
        assertBool "vod" ("#EXT-X-PLAYLIST-TYPE:VOD" `elem` ls)
        assertBool "extinf u1" ("#EXTINF:1.000," `elem` ls)
        assertBool "extinf u2" ("#EXTINF:1.200," `elem` ls)
        assertEqual "last line" "#EXT-X-ENDLIST" (last ls),
      testCase "empty entries render valid skeleton with TARGETDURATION 1" $ do
        let m3u8 = renderVodPlaylist "https://s3/init.mp4" []
        assertBool "target" ("#EXT-X-TARGETDURATION:1" `elem` T.lines m3u8)
        assertBool "map still present" (T.isInfixOf "#EXT-X-MAP" m3u8),
      testCase "renderEmptyPlaylist has no MAP and ends the list" $ do
        let m3u8 = renderEmptyPlaylist
        assertBool "no map" (not (T.isInfixOf "#EXT-X-MAP" m3u8))
        assertEqual "last line" "#EXT-X-ENDLIST" (last (T.lines m3u8)),
      testProperty "TARGETDURATION >= every EXTINF duration (RFC 8216)" $
        forAll (listOf1 (getPositive <$> arbitrary)) $ \durs ->
          let m3u8 = renderVodPlaylist "init" [(d, "u") | d <- durs]
              extinfs = parseExtinfs m3u8
           in fromIntegral (parseTarget m3u8) >= maximum extinfs
                && length extinfs == length durs
    ]

-- | Parse @#EXT-X-TARGETDURATION:\<n\>@ — fails the test via 'error' if
-- absent, which is the desired outcome for a malformed render.
parseTarget :: Text -> Int
parseTarget m3u8 =
  case [T.drop 22 l | l <- T.lines m3u8, "#EXT-X-TARGETDURATION:" `T.isPrefixOf` l] of
    (t : _) -> read (T.unpack t)
    [] -> error "no TARGETDURATION line"

parseExtinfs :: Text -> [Double]
parseExtinfs m3u8 =
  [ read (T.unpack dur)
  | l <- T.lines m3u8,
    "#EXTINF:" `T.isPrefixOf` l,
    let dur = T.takeWhile (/= ',') (T.drop 8 l)
  ]
