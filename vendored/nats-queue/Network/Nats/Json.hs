{-# LANGUAGE Rank2Types #-}

module Network.Nats.Json
  ( subscribe,
    publish,
    requestMany,
  )
where

import Control.Applicative ((<$>))
import qualified Data.Aeson as AE
import Data.Maybe (mapMaybe)
import Network.Nats (Nats, NatsSID)
import qualified Network.Nats as N

-- | Publish a message
publish ::
  (AE.ToJSON a) =>
  Nats ->
  -- | Subject
  String ->
  -- | Data
  a ->
  IO ()
publish nats subject body = N.publish nats subject (AE.encode body)

-- | Subscribe to a channel, optionally specifying queue group
-- If the JSON cannot be properly parsed, the message is ignored
subscribe ::
  (AE.FromJSON a) =>
  Nats ->
  -- | Subject
  String ->
  -- | Queue
  Maybe String ->
  -- | Callback
  ( NatsSID ->
    String ->
    a ->
    Maybe String ->
    IO ()
  ) ->
  -- | SID of subscription
  IO NatsSID
subscribe nats subject queue jcallback = N.subscribe nats subject queue cb
  where
    cb sid subj msg repl = case AE.eitherDecode msg of
      Right body -> jcallback sid subj body repl
      -- Ignore when there is an error decoding
      Left err -> putStrLn $ err ++ ": " ++ show msg

requestMany ::
  (AE.ToJSON a, AE.FromJSON b) =>
  Nats ->
  -- | Subject
  String ->
  -- | Body
  a ->
  -- | Timeout in microseconds
  Int ->
  IO [b]
requestMany nats subject body time =
  decodeAndFilter <$> N.requestMany nats subject (AE.encode body) time
  where
    decodeAndFilter = mapMaybe AE.decode
