{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | Leader-side PTZ status cache (Phase 5). Subscribes
-- @hnvr.ptz.status.>@ and keeps the latest 'PtzStatusMsg' per camera
-- slug; the @/PtzStatusCamera@ endpoint (1 Hz UI poll) reads it.
--
-- Process-wide TVar, same shape as 'Hnvr.Web.BusRegistry': the
-- subscription is created in an IHP initializer, controllers can't
-- receive it through 'option'.
module Hnvr.Web.PtzStatusCache
  ( startPtzStatusCache,
    latestPtzStatus,
  )
where

import Control.Concurrent.Async (async)
import Control.Concurrent.STM (TVar, atomically, modifyTVar', newTVarIO, readTVarIO)
import Control.Exception (SomeAsyncException (..), SomeException, fromException, throwIO, try)
import Control.Monad (forever)
import Data.Aeson (decodeStrict')
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as T
import Hnvr.Core.Logging (logError, logInfo)
import Hnvr.Core.Ptz (PtzStatusMsg)
import Hnvr.Nats.Bus (Bus, Message (..))
import qualified Hnvr.Nats.Bus as Bus
import System.IO.Unsafe (unsafePerformIO)

{-# NOINLINE ptzStatusStore #-}
ptzStatusStore :: TVar (Map Text PtzStatusMsg)
ptzStatusStore = unsafePerformIO (newTVarIO Map.empty)

startPtzStatusCache :: Bus -> IO ()
startPtzStatusCache bus = do
  _ <- async loop
  logInfo "PtzStatusCache: subscribed to hnvr.ptz.status.>"
  where
    loop = do
      sub <- Bus.subscribe bus "hnvr.ptz.status.>"
      forever $ do
        msg <- Bus.readMessage sub
        r <- try (handle msg)
        case r of
          Right () -> pure ()
          Left (e :: SomeException) -> case fromException e of
            Just (SomeAsyncException _) -> throwIO e
            Nothing -> logError ("PtzStatusCache: " <> T.pack (show e))
    handle msg =
      case decodeStrict' (msgPayload msg) of
        Nothing -> logError ("PtzStatusCache: undecodable status on " <> msgSubject msg)
        Just st -> atomically (modifyTVar' ptzStatusStore (Map.insert (slugOf (msgSubject msg)) st))
    slugOf s = case T.breakOnEnd "." s of
      ("", _) -> s
      (_, t) -> t

latestPtzStatus :: Text -> IO (Maybe PtzStatusMsg)
latestPtzStatus slug = Map.lookup slug <$> readTVarIO ptzStatusStore
