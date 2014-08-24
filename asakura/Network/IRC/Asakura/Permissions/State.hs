{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}

-- |Internal state for the permissions module
module Network.IRC.Asakura.Permissions.State where

import Control.Applicative    ((<$>), (<*>), (<|>), pure)
import Control.Concurrent.STM (TVar, atomically, newTVar, readTVar)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Data.Aeson             (FromJSON(..), ToJSON(..), Value(..), (.=), (.:), (.:?), (.!=), object)
import Data.Map               (Map)
import Data.Ord               (Down(..), comparing)
import Data.Text              (Text)
import Network                (HostName)
import Network.IRC.Asakura.State
import Network.IRC.Asakura.Utils

import qualified Data.Map as M

-- *Permission levels

-- |Users are divided up into three classes. In the Admin/TrustedUser
-- classes, lower integers represent higher permission levels (0 being
-- the highest, just like in a priority-based algorithm).
data PermissionLevel = God
                     | Admin   Int
                     | Trusted Int
                     deriving (Eq, Show)

instance Ord PermissionLevel where
    -- All gods are equal.
    compare God God = EQ

    -- Lesser mortals are ranked in reverse integer order.
    compare (Admin   i) (Admin   j) = comparing Down i j
    compare (Trusted i) (Trusted j) = comparing Down i j

    -- And constructor order determines the rest.
    compare God       _ = GT
    compare (Admin _) _ = GT

    compare _ _ = LT

instance ToJSON PermissionLevel where
    toJSON God         = String "god"
    toJSON (Admin i)   = object [ "admin"   .= i ]
    toJSON (Trusted i) = object [ "trusted" .= i ]

instance FromJSON PermissionLevel where
    parseJSON (String "god") = pure God
    parseJSON (Object v)     = (Admin <$> v .: "admin") <|> (Trusted <$> v .: "trusted")
    parseJSON _ = fail "Expected object or string"

-- *State

-- |A uniquely-identified permission. When determining someone's
-- permission in a given situation, the better permission takes
-- priority: so if someone is a network admin and a trusted user in
-- the channel in question, the network admin permission wins.
data PermissionDef = PChan Text HostName Text
                   -- ^Nick, network, channel
                   | PNet  Text HostName
                   -- ^Nick, network
                   deriving (Eq, Show)

-- |The private state of this module.
data PermissionState = PermissionState
    { _permissions :: TVar [(PermissionDef, PermissionLevel)]
    -- ^List of permissions known to the bot.
    }

-- *Snapshotting

data PermissionStateSnapshot = PermissionStateSnapshot
    { _ssPermissions :: Map HostName (Map Text UserPermissions)
    -- ^host -> nick -> (network permission, channel -> channel permission)
    }

-- |The permissions of a single user
data UserPermissions = UserPermissions (Maybe PermissionLevel) (Map Text PermissionLevel)

instance ToJSON UserPermissions where
    toJSON (UserPermissions (Just def) ps) | M.null ps = object [ "network" .= toJSON def ]
                                           | otherwise = object [ "network"  .= toJSON def
                                                                , "channels" .= toJSON ps
                                                                ]
    toJSON (UserPermissions Nothing    ps) | M.null ps = Null
                                           | otherwise = object [ "channels" .= toJSON ps ]

instance FromJSON UserPermissions where
    parseJSON (Object v) = UserPermissions
                             <$> v .:? "network"
                             <*> v .:? "channels" .!= M.fromList []
    parseJSON _ = fail "Expected object"

instance ToJSON PermissionStateSnapshot where
    toJSON ss = toJSON . _ssPermissions $ ss

instance FromJSON PermissionStateSnapshot where
    parseJSON v = PermissionStateSnapshot
                    <$> parseJSON v

instance Snapshot PermissionState PermissionStateSnapshot where
    snapshotSTM state = do
      perms <- readTVar . _permissions $ state
      return PermissionStateSnapshot { _ssPermissions = toPermTree perms }

      where toPermTree = fmap (fmap mergeUserPermissions . M.fromList . collect) . M.fromList . collect . map extractBits

            -- Turn the 'PermissionDef' into something we can process
            -- with standard functions
            extractBits (PChan nick hostname channel, pdef) = (hostname, (nick, UserPermissions Nothing $ M.fromList [(channel, pdef)]))
            extractBits (PNet nick hostname, pdef)          = (hostname, (nick, UserPermissions (Just pdef) $ M.fromList []))

            -- Merge the UserPermissions into a single one
            mergeUserPermissions = foldl mergeUP defUP
                where defUP = UserPermissions Nothing (M.fromList [])
                      mergeUP (UserPermissions a m1) (UserPermissions b m2) = UserPermissions (a <|> b) $ M.union m1 m2

instance Rollback PermissionStateSnapshot PermissionState where
    rollbackSTM state = do
      tvarP <- newTVar . fromPermTree . _ssPermissions $ state
      return PermissionState { _permissions = tvarP }

      where fromPermTree = concatMap fromNetworkMap . M.toList

            fromNetworkMap (network, nickmap) = concatMap (fromNickMap network) $ M.toList nickmap

            fromNickMap network (nick, ups) = fromUserPerms network nick ups

            fromUserPerms network nick (UserPermissions (Just def) cps) = (PNet nick network, def) : map (fromChanMap network nick) (M.toList cps)
            fromUserPerms network nick (UserPermissions Nothing cps)    = map (fromChanMap network nick) (M.toList cps)

            fromChanMap network nick (channel, perm) = (PChan nick network channel, perm)

-- *Initialisation

-- |Initialise a fresh permission state. As in the Command module,
-- this should only be done once and the state shared.
initialise :: MonadIO m => m PermissionState
initialise = do
  tvarP <- liftIO . atomically . newTVar $ []
  return PermissionState { _permissions = tvarP }