{-# LANGUAGE OverloadedStrings #-}

-- | NATS bus abstraction backed by @nats-queue@.
--
-- @nats-queue@ is a 2017-era core-NATS client (no TLS, no JetStream).
-- We wrap it here so the rest of HNVR sees a stable, Text-based API
-- with aeson payloads. JetStream functionality lands when we either
-- vendor a JetStream-aware fork or fall back to the @nats@ CLI subprocess
-- (decision deferred per Phase 0 plan — see @design_docs/02-tech-stack.md@).
--
-- Concurrency model: subscriptions deliver on nats-queue's single
-- receiver thread. The callback here just pushes to a @TChan@ so
-- downstream consumers can read from multiple green threads safely.
module Hnvr.Nats.Bus
  ( -- * Connection
    Bus,
    BusConfig (..),
    defaultConfig,
    withBus,
    connect,
    disconnect,
    hostFromUri,

    -- * Pub/sub
    publish,
    publishJson,
    subscribe,
    readMessage,
    drainSubscription,
    Subscription,
    unsubscribe,
    Message (..),

    -- * Request/reply
    request,
    requestJson,
    reply,
  )
where

import Control.Concurrent.STM
import Control.Exception (bracket)
import Data.Aeson (FromJSON, ToJSON, encode)
import qualified Data.Aeson
import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as BL
import Data.Text (Text)
import qualified Data.Text as T
import Network.Nats (Nats, NatsSID)
import qualified Network.Nats as Nats
import System.Timeout (timeout)

-- | Opaque handle to a connected bus.
newtype Bus = Bus {busNats :: Nats}

-- | Connection configuration. URI form: @nats://user:password\@host:port@.
data BusConfig = BusConfig
  { busUri :: !String,
    busOnReconnect :: !(String -> Int -> IO ()),
    busOnDisconnect :: !(String -> IO ())
  }

-- | Sensible defaults for local dev (@nats://nats:nats\@localhost:4222@).
-- Reconnect/disconnect callbacks are no-ops; wire real ones for production.
defaultConfig :: BusConfig
defaultConfig =
  BusConfig
    { busUri = "nats://nats:nats@localhost:4222",
      busOnReconnect = \_ _ -> pure (),
      busOnDisconnect = \_ -> pure ()
    }

-- | Bracket a bus connection: ensures 'disconnect' runs even on exception.
withBus :: BusConfig -> (Bus -> IO a) -> IO a
withBus cfg = bracket (connect cfg) disconnect

-- | Connect to a NATS server. Throws 'Nats.NatsException' on failure.
connect :: BusConfig -> IO Bus
connect cfg = do
  let settings =
        Nats.NatsSettings
          { Nats.natsHosts = [hostFromUri (busUri cfg)],
            Nats.natsOnReconnect = \_ (h, p) -> busOnReconnect cfg h p,
            Nats.natsOnDisconnect = \_ s -> busOnDisconnect cfg s
          }
  Bus <$> Nats.connectSettings settings

-- | Disconnect and free the underlying receiver thread.
disconnect :: Bus -> IO ()
disconnect = Nats.disconnect . busNats

-- | Parse @nats://user:pass\@host:port@ into a 'Nats.NatsHost'.
-- We re-implement parsing instead of using 'Nats.connect' so we can supply
-- custom callbacks via 'Nats.connectSettings'.
hostFromUri :: String -> Nats.NatsHost
hostFromUri uri =
  let schemeLen = 7 -- length "nats://"
      rest0 = drop schemeLen uri
      (userInfo, rest1) = span (/= '@') rest0
      (user, pass) = case break (== ':') userInfo of
        (u, ':' : p) -> (u, p)
        (u, _) -> (u, "nats")
      rest2 = drop 1 rest1
      (host, portStr) = case break (== ':') rest2 of
        (h, ':' : p) -> (h, p)
        (h, _) -> (h, "4222")
      port = read portStr
   in Nats.NatsHost
        { Nats.natsHHost = host,
          Nats.natsHPort = port,
          Nats.natsHUser = user,
          Nats.natsHPass = pass
        }

-- | A received message handed to a subscription callback.
data Message = Message
  { msgSubject :: !Text,
    msgPayload :: !ByteString,
    msgReplyTo :: !(Maybe Text)
  }
  deriving (Eq, Show)

-- | Opaque subscription handle.
data Subscription = Subscription
  { subSid :: !NatsSID,
    subChan :: !(TChan Message)
  }

-- | Publish raw bytes to a subject. Best-effort: nats-queue swallows
-- network errors here (matches NATS core semantics — fire and forget).
publish :: Bus -> Text -> ByteString -> IO ()
publish bus subject payload =
  Nats.publish (busNats bus) (T.unpack subject) (BL.fromStrict payload)

-- | Publish a JSON-encoded payload.
publishJson :: (ToJSON a) => Bus -> Text -> a -> IO ()
publishJson bus subject val =
  publish bus subject (BL.toStrict (encode val))

-- | Subscribe to a subject. Returns a 'Subscription' carrying a 'TChan'
-- that receives every matching message.
subscribe :: Bus -> Text -> IO Subscription
subscribe bus subject = do
  chan <- newTChanIO
  let cb _sid subj payload mreply =
        atomically $
          writeTChan
            chan
            Message
              { msgSubject = T.pack subj,
                msgPayload = BL.toStrict payload,
                msgReplyTo = T.pack <$> mreply
              }
  sid <- Nats.subscribe (busNats bus) (T.unpack subject) Nothing cb
  pure Subscription {subSid = sid, subChan = chan}

-- | Read the next message from a subscription's channel. Blocks.
readMessage :: Subscription -> IO Message
readMessage sub = atomically $ readTChan (subChan sub)

-- | Remove and return all currently-queued messages, oldest first.
-- Non-blocking; pairs with 'readMessage' for consumers that coalesce
-- bursty commands (PTZ latest-wins — a superseded intent must never
-- execute late).
drainSubscription :: Subscription -> IO [Message]
drainSubscription sub = atomically (go [])
  where
    go acc = do
      m <- tryReadTChan (subChan sub)
      case m of
        Nothing -> pure (reverse acc)
        Just x -> go (x : acc)

-- | Cancel a subscription. Best-effort.
unsubscribe :: Bus -> Subscription -> IO ()
unsubscribe bus sub = Nats.unsubscribe (busNats bus) (subSid sub)

-- | One-shot request/reply: publishes @payload@ on @subject@ and waits up
-- to @timeoutMicros@ for the first reply.
--
-- Implementation: wraps @nats-queue@'s 'Nats.request' with
-- 'System.Timeout.timeout'. @Nats.request@ blocks on an 'MVar' which our
-- timeout will interrupt via async exception; the internal 'bracket'
-- ensures the inbox subscription is cleaned up. Returns 'Nothing' on
-- timeout or no-responder.
request ::
  Bus ->
  -- | Request subject
  Text ->
  -- | Request payload
  ByteString ->
  -- | Timeout in microseconds
  Int ->
  IO (Maybe ByteString)
request bus subject payload timeoutMicros = do
  mResp <-
    timeout timeoutMicros $
      Nats.request (busNats bus) (T.unpack subject) (BL.fromStrict payload)
  pure (BL.toStrict <$> mResp)

-- | JSON-typed 'request'. Decodes the reply payload into @resp@; returns
-- 'Nothing' on timeout OR parse failure. Callers that need to distinguish
-- the two should call 'request' and decode manually.
requestJson ::
  (ToJSON req, FromJSON resp) =>
  Bus ->
  Text ->
  req ->
  Int ->
  IO (Maybe resp)
requestJson bus subject req timeoutMicros = do
  let payload = BL.toStrict (encode req)
  mResp <- request bus subject payload timeoutMicros
  pure (mResp >>= Data.Aeson.decodeStrict)

-- | Reply to a previously-received request message: publishes @payload@ on
-- the supplied reply-to subject. No-op if the reply-to is 'Nothing' (the
-- original sender didn't supply one).
reply :: Bus -> Maybe Text -> ByteString -> IO ()
reply bus mReplyTo payload =
  case mReplyTo of
    Nothing -> pure ()
    Just replyTo -> publish bus replyTo payload
