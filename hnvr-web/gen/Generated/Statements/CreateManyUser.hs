-- This file is auto generated and will be overriden regulary.
{-# OPTIONS_GHC -Wno-unused-imports -Wno-dodgy-imports -Wno-unused-matches #-}
module Generated.Statements.CreateManyUser (statement) where

import Prelude (($), (.), (<$>), (<*>), (<>), (+), (*), (-), show, fromIntegral, length, null, zip, mconcat, (++), Maybe(..), (!!), map, Bool(..), Int, Integer, pure, (&&), not)
import Generated.ActualTypes
import Generated.Enums
import IHP.ModelSupport.Types (Id'(..), MetaBag(..))
import qualified Hasql.Statement as Statement
import qualified Hasql.Decoders as Decoders
import qualified Hasql.Encoders as Encoders
import qualified Hasql.Mapping.IsScalar as Mapping
import Hasql.PostgresqlTypes ()
import IHP.Job.Queue ()
import Data.Functor.Contravariant (contramap, (>$<))
import Data.Default (def)
import qualified Data.Dynamic
import Data.UUID (UUID)
import Data.Text (Text)
import Data.Int (Int16, Int32, Int64)
import Data.Time.Clock (UTCTime)
import Data.Time.LocalTime (LocalTime, TimeOfDay)
import qualified Data.Time.Calendar
import Data.Scientific (Scientific)
import qualified Data.Aeson
import qualified Database.PostgreSQL.Simple.Types
import PostgresqlTypes.Point (Point)
import PostgresqlTypes.Polygon (Polygon)
import PostgresqlTypes.Inet (Inet)
import PostgresqlTypes.Tsvector (Tsvector)
import PostgresqlTypes.Interval (Interval)

import qualified Generated.Statements.RowDecoderUser as RowDecoder
import Data.Bits (testBit)
import Data.Maybe (catMaybes)
import qualified Data.Text as Text
import qualified Data.List as List
statement :: [Integer] -> Statement.Statement [Generated.ActualTypes.User] [Generated.ActualTypes.User]
statement touchedFieldsList = Statement.unpreparable (sql touchedFieldsList) (encoder touchedFieldsList) decoder

sql :: [Integer] -> Text
sql touchedFieldsList =
    let (valueGroups, _) = List.foldl' (\(gs, offset) tf ->
            let (g, offset') = valueGroup tf offset
            in (gs ++ [g], offset')
            ) ([], 1) touchedFieldsList
    in "INSERT INTO users (id, email, password_hash, is_admin, locked_at, failed_login_attempts, last_login_at, timezone, created_at) VALUES "
        <> Text.intercalate ", " valueGroups
        <> " RETURNING id, email, password_hash, is_admin, locked_at, failed_login_attempts, last_login_at, timezone, created_at"
  where
    columnMeta = [(0, True), (1, False), (2, False), (3, True), (4, False), (5, True), (6, False), (7, False), (8, True)]
    valueGroup tf offset =
        let step (parts, off) (bitIdx, hasDefault) =
                if hasDefault && not (testBit tf bitIdx)
                    then (parts ++ ["DEFAULT"], off)
                    else (parts ++ ["$" <> Text.pack (show off)], off + 1)
            (parts, offset') = List.foldl' step ([], offset) columnMeta
        in ("(" <> Text.intercalate ", " parts <> ")", offset')

encoder :: [Integer] -> Encoders.Params [Generated.ActualTypes.User]
encoder touchedFieldsList = mconcat $ List.zipWith (\i tf -> contramap (!! i) (singleEncoder tf)) [0..] touchedFieldsList

singleEncoder :: Integer -> Encoders.Params Generated.ActualTypes.User
singleEncoder touchedFields = mconcat $ catMaybes
    [ if testBit touchedFields 0 then Just ((.id) >$< Encoders.param (Encoders.nonNullable Mapping.encoder)) else Nothing
    , Just ((.email) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    , Just ((.passwordHash) >$< Encoders.param (Encoders.nonNullable Encoders.text))
    , if testBit touchedFields 3 then Just ((.isAdmin) >$< Encoders.param (Encoders.nonNullable Encoders.bool)) else Nothing
    , Just ((.lockedAt) >$< Encoders.param (Encoders.nullable Encoders.timestamptz))
    , if testBit touchedFields 5 then Just ((.failedLoginAttempts) >$< Encoders.param (Encoders.nonNullable (fromIntegral >$< Encoders.int4))) else Nothing
    , Just ((.lastLoginAt) >$< Encoders.param (Encoders.nullable Encoders.timestamptz))
    , Just ((.timezone) >$< Encoders.param (Encoders.nullable Encoders.text))
    , if testBit touchedFields 8 then Just ((.createdAt) >$< Encoders.param (Encoders.nonNullable Encoders.timestamptz)) else Nothing
    ]

decoder :: Decoders.Result [Generated.ActualTypes.User]
decoder = Decoders.rowList RowDecoder.rowDecoder
