{-# LANGUAGE OverloadedStrings #-}

-- | Per-host ConfigWatcher (node-side).
--
-- Subscribes to the @hnvr.commands.assign.>@ subject and logs each
-- assignment decision. Slice 5 MVP just acknowledges receipt — the
-- actual CaptureSupervisor integration (start/stop workers based on
-- the new assignment) lands in Phase 3 when the CaptureWorker is
-- embedded in the node process instead of running standalone.
--
-- Also subscribes @hnvr.commands.control.<host>.<cam>.<action>@ for
-- start/stop/restart directives from the leader (also stubbed here).
module Hnvr.Node.ConfigWatcher
  ( startConfigWatcher,
  )
where

import Control.Applicative ((<*>))
import Control.Concurrent.Async (async)
import Control.Monad (forever)
import Data.Aeson (FromJSON (..), decodeStrict')
import Data.Aeson.Types (object, withObject, (.:))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Hnvr.Nats.Bus (Bus, Message (..))
import qualified Hnvr.Nats.Bus as Bus

-- | Wire payload for @hnvr.commands.assign.<slug>@.
data AssignMsg = AssignMsg
  { amSlug :: !Text,
    amHost :: !Text
  }
  deriving (Show)

instance FromJSON AssignMsg where
  parseJSON = withObject "AssignMsg" $ \o ->
    AssignMsg
      <$> o .: "slug"
      <*> o .: "host"

-- | Spawn the subscriber. Reads messages forever in a background async.
-- host is this node's id — used to filter assignments that target us.
startConfigWatcher :: Bus -> Text -> IO ()
startConfigWatcher bus host = do
  _ <- async assignLoop
  putStrLn ("HNVR ConfigWatcher: subscribed to hnvr.commands.assign.> as " <> T.unpack host)
  where
    assignLoop =
      forever $ do
        sub <- Bus.subscribe bus "hnvr.commands.assign.>"
        msg <- Bus.readMessage sub
        handleAssign host msg

-- | Decode the assign message and decide whether this camera is now
-- ours. Slice 5 stub: just log. Slice 6+: start/stop CaptureSupervisor.
handleAssign :: Text -> Message -> IO ()
handleAssign host msg =
  case decodeStrict' (msgPayload msg) :: Maybe AssignMsg of
    Just am -> do
      let ours = am.amHost == host
      TIO.putStrLn $
        "[ConfigWatcher] assign "
          <> am.amSlug
          <> " -> "
          <> am.amHost
          <> (if ours then " (ours)" else " (not ours)")
    Nothing ->
      TIO.putStrLn $
        "[ConfigWatcher] failed to decode assign payload on " <> msgSubject msg
