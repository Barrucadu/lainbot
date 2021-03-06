-- |
-- Module      : Yukibot.Monad
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Stability   : experimental
-- Portability : portable
module Yukibot.Monad where

import Control.Applicative ((<*))
import Control.Monad.Trans.Free (liftF, iterT)
import Data.Text (Text)
import qualified Database.MongoDB as M

import qualified Yukibot.Backend as Backend
import qualified Yukibot.Plugin.Builtin as Builtin
import qualified Yukibot.Mongo as Mongo
import Yukibot.Types

-------------------------------------------------------------------------------
-- * Monad

-- | Run a 'BackendM' computation.
runBackendM :: Builtin.BuiltinState
  -- ^ The state of the \"builtin\" plugin.
  -> Mongo.MongoConfig
  -- ^ Connection info for the MongoDB database.
  -> InstantiatedBackend
  -- ^ The instantiated backend.
  -> Maybe PluginName
  -- ^ The currently-executing plugin. If @Nothing@, actions which
  -- need this (such as MongoDB queries) fail with 'error'.
  -> Event
  -- ^ The current event.
  -> BackendM a
  -- ^ The effectful computation to perform.
  -> IO a
runBackendM st mc ib pn ev = runB where
  runB :: BackendM a -> IO a
  runB = iterT go

  go (Reply msg k) = k <* Backend.sendAction (eventHandle ev) (case eventChannel ev of
    Just cname -> Say cname [eventUser ev] msg
    Nothing    -> Whisper (eventUser ev) msg)
  go (QuickReply msg k) = k <* Backend.sendAction (eventHandle ev) (case eventChannel ev of
    Just cname -> Say cname [] msg
    Nothing    -> Whisper (eventUser ev) msg)
  go (GetCommandPrefixIn   mcname k) = k =<< runB (Builtin.getCommandPrefixIn   st mcname)
  go (GetDisabledPluginsIn mcname k) = k =<< runB (Builtin.getDisabledPluginsIn st mcname)
  go (GetEnabledCommandsIn mcname k) = k =<< runB (Builtin.getEnabledCommandsIn st mcname)
  go (GetEnabledMonitorsIn mcname k) = k =<< runB (Builtin.getEnabledMonitorsIn st mcname)
  go (SendAction act k) = k <* Backend.sendAction (eventHandle ev) act
  go (GetInstance k) = k ib
  go (GetEvent    k) = k ev
  go (GetDeities  k) = k =<< runB (Builtin.getDeities st)
  go (GetBackendSig k) = k bsig
  go (QueryMongo selBy sortBy k) = requirePlugin $ \pname ->
    k =<< Mongo.queryMongo mc pname bsig selBy sortBy
  go (InsertMongo ds k) = requirePlugin $ \pname ->
    k <* Mongo.insertMongo mc pname bsig ds
  go (UpsertMongo selBy doc k) = requirePlugin $ \pname ->
    k <* Mongo.upsertMongo mc pname bsig selBy doc
  go (DeleteMongo selBy k) = requirePlugin $ \pname ->
    k <* Mongo.deleteMongo mc pname bsig selBy
  go (DoMongo act k) = requirePlugin $ \pname ->
    k <* Mongo.doMongo mc pname act

  requirePlugin f = maybe (error "Expected PluginName in action executing outside of a plugin context.") f pn

  -- Backend signature
  bsig = (instBackendName ib, instSpecificName ib, instIndex ib)

-------------------------------------------------------------------------------
-- * Actions

-- | Join a channel.
joinChannel :: ChannelName -> BackendM ()
joinChannel cname = sendAction (Join cname)

-- | Leave a channel.
leaveChannel :: ChannelName -> BackendM ()
leaveChannel cname = sendAction (Leave cname)

-- | Reply to the last message.
reply :: Text -> BackendM ()
reply msg = liftF $ Reply msg ()

-- | Reply to the last message, without addressing the user.
quickReply :: Text -> BackendM ()
quickReply msg = liftF $ QuickReply msg ()

-- | Send a message to a channel, optionally addressed to some users.
say :: ChannelName -> [UserName] -> Text -> BackendM ()
say cname users msg = sendAction (Say cname users msg)

-- | Send a message to a user.
whisper :: UserName -> Text -> BackendM ()
whisper user msg = sendAction (Whisper user msg)

-- | Disconnect from the backend.
disconnect :: BackendM ()
disconnect = sendAction Terminate

-- | Get the command prefix in the current channel.
getCommandPrefix :: BackendM Text
getCommandPrefix = getCommandPrefixIn . eventChannel =<< getEvent

-- | Get the command prefix in an arbitrary channel.
getCommandPrefixIn :: Maybe ChannelName -> BackendM Text
getCommandPrefixIn mcname = liftF $ GetCommandPrefixIn mcname id

-- | Get the disabled plugins in the current channel.
getDisabledPlugins :: BackendM [PluginName]
getDisabledPlugins = getDisabledPluginsIn . eventChannel =<< getEvent

-- | Get the disabled plugins in an arbitrary channel.
getDisabledPluginsIn :: Maybe ChannelName -> BackendM [PluginName]
getDisabledPluginsIn mcname = liftF $ GetDisabledPluginsIn mcname id

-- | Get the enabled commands in the current channel.
getEnabledCommands :: BackendM [(PluginName, CommandName, Text)]
getEnabledCommands = getEnabledCommandsIn . eventChannel =<< getEvent

-- | Get the enabled commands in an arbitrary channel.
getEnabledCommandsIn :: Maybe ChannelName -> BackendM [(PluginName, CommandName, Text)]
getEnabledCommandsIn mcname = liftF $ GetEnabledCommandsIn mcname id

-- | Get the enabled monitors in the current channel.
getEnabledMonitors :: BackendM [(PluginName, MonitorName)]
getEnabledMonitors = getEnabledMonitorsIn . eventChannel =<< getEvent

-- | Get the enabled monitors in an arbitrary channel.
getEnabledMonitorsIn :: Maybe ChannelName -> BackendM [(PluginName, MonitorName)]
getEnabledMonitorsIn mcname = liftF $ GetEnabledMonitorsIn mcname id

-- | Get the instantiated backend.
getInstance :: BackendM InstantiatedBackend
getInstance = liftF $ GetInstance id

-- | Get the current event.
getEvent :: BackendM Event
getEvent = liftF $ GetEvent id

-- | Get the deities.
getDeities :: BackendM [UserName]
getDeities = liftF $ GetDeities id

-- | Get the \"backend signature\". This can be used to uniquely
-- identify a backend in the configuration (as long as, e.g., backend
-- arrays aren't re-ordered).
getBackendSig :: BackendM BackendSig
getBackendSig = liftF $ GetBackendSig id

-- | Check if the current user is deified.
isDeified :: BackendM Bool
isDeified = do
  deities <- getDeities
  ev      <- getEvent
  pure (eventUser ev `elem` deities)

-- | Send a backend action.
sendAction :: Action -> BackendM ()
sendAction act = liftF $ SendAction act ()

-------------------------------------------------------------------------------
-- ** Database

-- | Query the MongoDB collection for this plugin. Each plugin has its
-- own collection.
queryMongo :: M.Selector -> M.Order -> BackendM [M.Document]
queryMongo selBy sortBy = liftF $ QueryMongo selBy sortBy id

-- | Insert into the MongoDB collection.
insertMongo :: [M.Document] -> BackendM ()
insertMongo ds = liftF $ InsertMongo ds ()

-- | Upsert a value in the MongoDB collection: replace the first
-- document in the selection if there is one; otherwise insert a new
-- document.
upsertMongo :: M.Selector -> M.Document -> BackendM ()
upsertMongo selBy doc = liftF $ UpsertMongo selBy doc ()

-- | Delete from the MongoDB collection.
deleteMongo :: M.Selector -> BackendM ()
deleteMongo selBy = liftF $ DeleteMongo selBy ()

-- | Perform an arbitrary sequence of operations against the MongoDB
-- collection.
doMongo :: (M.Collection -> M.Action IO ()) -> BackendM ()
doMongo act = liftF $ DoMongo act ()
