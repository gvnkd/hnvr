{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | ONVIF media-service client (hand-rolled SOAP over HTTP).
--
-- Covers the config-sync subset:
--
--   * GetCapabilities (device service) — discover the media XAddr; the
--     path AND port vary per firmware (Hikvision-OEM: :80/onvif/media,
--     XM: :8899/onvif/media_service), so discovery is mandatory.
--   * Get/Set AudioEncoderConfiguration(s) + Options
--   * Get/Set VideoEncoderConfiguration(s) + Options
--
-- Auth: WS-Security UsernameToken, PasswordDigest =
-- @base64(sha1(nonce_bytes ++ created ++ password))@.
--
-- Parsers are pure and exported for golden-fixture tests
-- (@hnvr-ptz/test/fixtures/*.xml@ captured from live cameras).
-- Element lookup is namespace-prefix-agnostic (localName only): the
-- Hikvision-OEM stack uses @SOAP-ENV:@/@trt:@/@tt:@ prefixes, the XM
-- stack uses @s:@ and sometimes none.
module Hnvr.Onvif.Client
  ( OnvifCreds (..),
    OnvifError (..),
    discoverMediaXAddr,
    getAudioConfigs,
    getAudioOptions,
    getVideoConfigs,
    getVideoOptions,
    setAudioConfig,
    setVideoConfig,
    parseAudioConfigs,
    parseAudioOptions,
    parseVideoConfigs,
    parseVideoOptions,
    parseServiceXAddrs,
  )
where

import Control.Exception (SomeException, try)
import Control.Monad (void)
import Crypto.Hash (Digest, SHA1 (..), hash)
import Crypto.Random (getRandomBytes)
import qualified Data.ByteArray as BA
import Data.ByteString (ByteString)
import qualified Data.ByteString.Base64 as B64
import qualified Data.ByteString.Lazy as BL
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import Data.Time.Clock (UTCTime, getCurrentTime)
import Data.Time.Format (defaultTimeLocale, formatTime)
import Hnvr.Core.Onvif
import qualified Network.HTTP.Client as HC
import qualified Network.HTTP.Types as HT
import Text.Read (readMaybe)
import Text.XML (Document, Name (..), Node (..), def, elementName, parseLBS)
import Text.XML.Cursor

data OnvifCreds = OnvifCreds
  { ocUser :: !Text,
    ocPass :: !Text
  }
  deriving stock (Eq, Show)

data OnvifError
  = OnvifTransportError Text
  | OnvifHttpError Int Text
  | OnvifFault Text
  | OnvifParseError Text
  deriving stock (Eq, Show)

-- | GetCapabilities (Category=All) against the device service and pick
-- out the Media XAddr. Host/port here are the ONVIF endpoint's (e.g.
-- @192.168.0.198@ + @8899@), NOT the RTSP port.
discoverMediaXAddr ::
  HC.Manager -> OnvifCreds -> Text -> Int -> IO (Either OnvifError Text)
discoverMediaXAddr mgr creds host port = do
  let url = "http://" <> host <> ":" <> tshow port <> "/onvif/device_service"
  res <- soapCall mgr creds url "tds" "GetCapabilities" "<tds:Category>All</tds:Category>"
  pure $ do
    body <- res
    caps <- parseServiceXAddrs body
    case Map.lookup "media" caps of
      Just x -> Right x
      Nothing -> Left (OnvifParseError "GetCapabilities: no Media XAddr")

-- | Parse Capabilities into a lowercased service-name → XAddr map
-- ("media", "events", "ptz", "device", "imaging", "analytics", ...).
parseServiceXAddrs :: ByteString -> Either OnvifError (Map Text Text)
parseServiceXAddrs bs = do
  doc <- parseDoc bs
  let cur = fromDocument doc
      caps = cur $// laxElement "Capabilities"
  case caps of
    [] -> Left (OnvifParseError "no Capabilities element")
    (c : _) ->
      pure $
        Map.fromList
          [ (T.toLower (nameLocalName (elementName e)), fromMaybe "" (childText n "XAddr"))
          | n <- child c,
            NodeElement e <- [node n]
          ]

-- | GETs ---------------------------------------------------------------
getAudioConfigs :: HC.Manager -> OnvifCreds -> Text -> IO (Either OnvifError [AudioConfig])
getAudioConfigs mgr creds media = do
  res <- soapCall mgr creds media "trt" "GetAudioEncoderConfigurations" ""
  pure (res >>= parseAudioConfigs)

getAudioOptions :: HC.Manager -> OnvifCreds -> Text -> IO (Either OnvifError AudioOptions)
getAudioOptions mgr creds media = do
  res <- soapCall mgr creds media "trt" "GetAudioEncoderConfigurationOptions" ""
  pure (res >>= parseAudioOptions)

getVideoConfigs :: HC.Manager -> OnvifCreds -> Text -> IO (Either OnvifError [VideoConfig])
getVideoConfigs mgr creds media = do
  res <- soapCall mgr creds media "trt" "GetVideoEncoderConfigurations" ""
  pure (res >>= parseVideoConfigs)

getVideoOptions :: HC.Manager -> OnvifCreds -> Text -> IO (Either OnvifError VideoOptions)
getVideoOptions mgr creds media = do
  res <- soapCall mgr creds media "trt" "GetVideoEncoderConfigurationOptions" ""
  pure (res >>= parseVideoOptions)

-- | SETs ---------------------------------------------------------------

-- | Push one audio config (already clamped by 'Hnvr.Core.Onvif.clampAudio').
-- Units on the wire are spec units (kbps / kHz).
setAudioConfig :: HC.Manager -> OnvifCreds -> Text -> AudioConfig -> IO (Either OnvifError ())
setAudioConfig mgr creds media a = do
  let body =
        "<trt:Configuration token=\""
          <> esc (acToken a)
          <> "\">"
          <> el "Name" (esc (acName a))
          <> el "UseCount" (tshow (acUseCount a))
          <> el "Encoding" (audioEncodingText (acEncoding a))
          <> el "Bitrate" (tshow (acBitrateKbps a))
          <> el "SampleRate" (tshow (acSampleRateKhz a))
          <> "</trt:Configuration>"
          <> "<trt:ForcePersistence>true</trt:ForcePersistence>"
  res <- soapCall mgr creds media "trt" "SetAudioEncoderConfiguration" body
  pure (void' res)

setVideoConfig :: HC.Manager -> OnvifCreds -> Text -> VideoConfig -> IO (Either OnvifError ())
setVideoConfig mgr creds media v = do
  let codecSection = case vcEncoding v of
        VEncH264 -> codecEl "H264"
        VEncH265 -> codecEl "H265"
        _ -> ""
      codecEl tag =
        "<tt:"
          <> tag
          <> ">"
          <> el "GovLength" (tshow (vcGovLength v))
          <> maybe "" (el (tag <> "Profile") . esc) (vcCodecProfile v)
          <> "</tt:"
          <> tag
          <> ">"
      body =
        "<trt:Configuration token=\""
          <> esc (vcToken v)
          <> "\">"
          <> el "Name" (esc (vcName v))
          <> el "UseCount" (tshow (vcUseCount v))
          <> el "Encoding" (videoEncodingText (vcEncoding v))
          <> "<tt:Resolution>"
          <> el "Width" (tshow (vcWidth v))
          <> el "Height" (tshow (vcHeight v))
          <> "</tt:Resolution>"
          <> el "Quality" (tshowD (vcQuality v))
          <> "<tt:RateControl>"
          <> el "FrameRateLimit" (tshow (vcFps v))
          <> el "EncodingInterval" (tshow (vcEncodingInterval v))
          <> el "BitrateLimit" (tshow (vcBitrateKbps v))
          <> "</tt:RateControl>"
          <> codecSection
          <> "</trt:Configuration>"
          <> "<trt:ForcePersistence>true</trt:ForcePersistence>"
  res <- soapCall mgr creds media "trt" "SetVideoEncoderConfiguration" body
  pure (void' res)

-- | Response parsers -----------------------------------------------------
parseAudioConfigs :: ByteString -> Either OnvifError [AudioConfig]
parseAudioConfigs bs = do
  doc <- parseDoc bs
  let confs = fromDocument doc $// laxElement "Configurations"
  pure (mapMaybe mkAudio confs)
  where
    mkAudio c = do
      token <- attr "token" c
      name <- childText c "Name"
      useCount <- readT =<< childText c "UseCount"
      enc <- parseAudioEncoding <$> childText c "Encoding"
      br <- normalizeBitrateKbps <$> (readT =<< childText c "Bitrate")
      sr <- normalizeSampleRateKhz <$> (readT =<< childText c "SampleRate")
      pure (AudioConfig token name useCount enc br sr)

parseAudioOptions :: ByteString -> Either OnvifError AudioOptions
parseAudioOptions bs = do
  doc <- parseDoc bs
  let opts = innermostOptions doc
      encs = mapMaybe (\o -> parseAudioEncoding <$> childText o "Encoding") opts
      brs = normalizeBitrateKbps <$> concatMap (listItems "BitrateList") opts
      srs = normalizeSampleRateKhz <$> concatMap (listItems "SampleRateList") opts
  pure (AudioOptions encs brs srs)

parseVideoConfigs :: ByteString -> Either OnvifError [VideoConfig]
parseVideoConfigs bs = do
  doc <- parseDoc bs
  let confs = fromDocument doc $// laxElement "Configurations"
  pure (mapMaybe mkVideo confs)
  where
    mkVideo c = do
      token <- attr "token" c
      name <- descText c "Name"
      useCount <- readT =<< descText c "UseCount"
      enc <- parseVideoEncoding <$> descText c "Encoding"
      w <- readT =<< descText c "Width"
      h <- readT =<< descText c "Height"
      q <- readD =<< descText c "Quality"
      fps <- readT =<< descText c "FrameRateLimit"
      ei <- readT =<< descText c "EncodingInterval"
      br <- readT =<< descText c "BitrateLimit"
      -- GovLength: Hikvision-OEM (196) emits a junk flat GovLength=0
      -- plus the real one nested in the codec element; XM (198) nests
      -- it too; JPEG configs omit it entirely (0 = not applicable).
      let nestedGov =
            [ t
            | codec <- descendantLocal c ["H264", "H265", "Mpeg4"],
              Just t <- [childText codec "GovLength"]
            ]
      gov <- case nestedGov of
        (t : _) -> readT t
        [] -> maybe (Just 0) readT (childText c "GovLength")
      let prof = firstText (descendantLocal c ["H264Profile", "H265Profile", "Mpeg4Profile"])
      pure (VideoConfig token name useCount enc w h q fps ei br gov prof)
    -- Video config fields are arbitrarily nested (Resolution,
    -- RateControl, H264/H265 wrappers — vendor-dependent), so look
    -- up by local name anywhere below the Configurations element.
    descText c l = firstText (descendantLocal c [l])

parseVideoOptions :: ByteString -> Either OnvifError VideoOptions
parseVideoOptions bs = do
  doc <- parseDoc bs
  let opts = innermostOptions doc
      resos =
        [ (w, h)
        | o <- opts,
          r <- descendantLocal o ["ResolutionsAvailable"],
          Just w <- [readT =<< childText r "Width"],
          Just h <- [readT =<< childText r "Height"]
        ]
      encs =
        concatMap
          ( \o ->
              ["JPEG" | not (null (childLocal o "JPEG"))]
                <> ["H264" | not (null (childLocal o "H264"))]
                <> ["H265" | not (null (childLocal o "H265"))]
          )
          opts
      range l = case opts >>= \o -> descendantLocal o [l] of
        [] -> Nothing
        (r : _) -> (,) <$> (readT =<< childText r "Min") <*> (readT =<< childText r "Max")
  pure
    ( VideoOptions
        (map parseVideoEncoding encs)
        resos
        (range "FrameRateRange")
        (range "BitrateRange")
        (range "GovLengthRange")
    )

-- | SOAP plumbing --------------------------------------------------------

-- | One SOAP round-trip: builds the envelope (WSSE header + namespaced
-- body), POSTs, and returns the raw Body XML on success. A SOAP Fault
-- maps to 'OnvifFault'.
soapCall ::
  HC.Manager ->
  OnvifCreds ->
  Text ->
  Text ->
  Text ->
  Text ->
  IO (Either OnvifError ByteString)
soapCall mgr creds url ns op inner = do
  hdr <- wsseHeader creds
  let envelope =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
          <> "<soap:Envelope xmlns:soap=\"http://www.w3.org/2003/05/soap-envelope\""
          <> " xmlns:tt=\"http://www.onvif.org/ver10/schema\""
          <> " xmlns:trt=\"http://www.onvif.org/ver10/media/wsdl\""
          <> " xmlns:tds=\"http://www.onvif.org/ver10/device/wsdl\">"
          <> "<soap:Header>"
          <> hdr
          <> "</soap:Header><soap:Body>"
          <> "<"
          <> ns
          <> ":"
          <> op
          <> ">"
          <> inner
          <> "</"
          <> ns
          <> ":"
          <> op
          <> ">"
          <> "</soap:Body></soap:Envelope>"
  eRes <- try $ do
    req0 <- HC.parseRequest (T.unpack url)
    let req =
          req0
            { HC.method = "POST",
              HC.requestHeaders =
                [ ("Content-Type", "application/soap+xml; charset=utf-8"),
                  ("SOAPAction", "\"http://www.onvif.org/ver10/media/wsdl/" <> TE.encodeUtf8 op <> "\"")
                ],
              HC.requestBody = HC.RequestBodyBS (TE.encodeUtf8 envelope),
              HC.responseTimeout = HC.responseTimeoutMicro 10000000
            }
    HC.httpLbs req mgr
  pure $ case eRes of
    Left (e :: SomeException) -> Left (OnvifTransportError (T.pack (show e)))
    Right res ->
      let st = HT.statusCode (HC.responseStatus res)
          body = BL.toStrict (HC.responseBody res)
       in if st >= 200 && st < 300
            then case soapFault body of
              Just f -> Left (OnvifFault f)
              Nothing -> Right body
            else Left (OnvifHttpError st (TE.decodeUtf8Lenient body))

-- | The media wsdl wraps the schema payload: @trt:Options@ contains
-- @tt:Options@. A namespace-agnostic descendant query matches BOTH,
-- and every descendant-based reader then counts the payload twice.
-- Keep only Options elements that contain no nested Options.
innermostOptions :: Document -> [Cursor]
innermostOptions doc =
  [ o
  | o <- fromDocument doc $// laxElement "Options",
    null (descendantLocal o ["Options"])
  ]

-- | Extract a SOAP Fault reason, if the body carries one.
soapFault :: ByteString -> Maybe Text
soapFault bs = case parseDoc bs of
  Left _ -> Nothing
  Right doc ->
    let fs = fromDocument doc $// laxElement "Fault"
     in case fs of
          [] -> Nothing
          (f : _) ->
            let reasons = concatMap (\l -> map (T.concat . ($/ content)) (descendantLocal f [l])) ["Text", "Reason", "Value"]
             in Just (fromMaybe "SOAP Fault" (headMay reasons))
  where
    headMay [] = Nothing
    headMay (x : _) = Just x

wsseHeader :: OnvifCreds -> IO Text
wsseHeader creds = do
  nonce <- getRandomBytes 16 :: IO ByteString
  now <- getCurrentTime
  let created = T.pack (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ" now)
      digest =
        B64.encode (BA.convert (hash (nonce <> TE.encodeUtf8 created <> TE.encodeUtf8 (ocPass creds)) :: Digest SHA1))
      nonceB64 = B64.encode nonce
      ut = "http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#"
  pure $
    "<wsse:Security xmlns:wsse=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd\""
      <> " xmlns:wsu=\"http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd\">"
      <> "<wsse:UsernameToken>"
      <> "<wsse:Username>"
      <> esc (ocUser creds)
      <> "</wsse:Username>"
      <> "<wsse:Password Type=\""
      <> ut
      <> "PasswordDigest\">"
      <> TE.decodeUtf8 digest
      <> "</wsse:Password>"
      <> "<wsse:Nonce EncodingType=\""
      <> ut
      <> "Base64Binary\">"
      <> TE.decodeUtf8 nonceB64
      <> "</wsse:Nonce>"
      <> "<wsu:Created>"
      <> created
      <> "</wsu:Created>"
      <> "</wsse:UsernameToken></wsse:Security>"

-- | XML cursor helpers (prefix-agnostic) ---------------------------------
parseDoc :: ByteString -> Either OnvifError Document
parseDoc bs =
  case parseLBS def (BL.fromStrict bs) of
    Left e -> Left (OnvifParseError (T.pack (show e)))
    Right d -> Right d

childText :: Cursor -> Text -> Maybe Text
childText c l = case c $/ laxElement l of
  (x : _) -> Just (T.concat (x $/ content))
  [] -> Nothing

attr :: Text -> Cursor -> Maybe Text
attr a c = case c $| laxAttribute a of
  (x : _) -> Just x
  [] -> Nothing

listItems :: Text -> Cursor -> [Int]
listItems l c = concatMap (mapMaybe (readT . T.strip) . ($/ content)) (descendantLocal c [l] >>= ($/ laxElement "Items"))

descendantLocal :: Cursor -> [Text] -> [Cursor]
descendantLocal c = concatMap (\l -> c $// laxElement l)

childLocal :: Cursor -> Text -> [Cursor]
childLocal c l = c $/ laxElement l

firstText :: [Cursor] -> Maybe Text
firstText [] = Nothing
firstText (c : _) = Just (T.concat (c $/ content))

readT :: Text -> Maybe Int
readT = readMaybe . T.unpack

readD :: Text -> Maybe Double
readD = readMaybe . T.unpack

void' :: Either OnvifError ByteString -> Either OnvifError ()
void' = void

el :: Text -> Text -> Text
el n v = "<tt:" <> n <> ">" <> v <> "</tt:" <> n <> ">"

esc :: Text -> Text
esc = T.concatMap f
  where
    f '&' = "&amp;"
    f '<' = "&lt;"
    f '>' = "&gt;"
    f '"' = "&quot;"
    f c = T.singleton c

tshow :: (Show a) => a -> Text
tshow = T.pack . show

tshowD :: Double -> Text
tshowD d
  | d == fromIntegral (round d :: Int) = T.pack (show (round d :: Int))
  | otherwise = T.pack (show d)
