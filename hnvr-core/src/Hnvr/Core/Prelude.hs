-- | HNVR-wide prelude: re-exports the few types every module touches.
--
-- Import as @import Hnvr.Core.Prelude as X@ (or @import qualified Hnvr.Core.Prelude as P@).
-- Keep this list small — anything that needs justification goes in its own module.
module Hnvr.Core.Prelude
  ( module X
  ) where

import Control.Monad.IO.Class as X (MonadIO, liftIO)
import Data.Aeson as X (FromJSON (..), ToJSON (..), Value)
import Data.ByteString as X (ByteString)
import Data.Text as X (Text)
import Data.Time.Clock as X (UTCTime)
import Data.UUID as X (UUID)

import Hnvr.Core.Geometry as X
import Hnvr.Core.Id as X
