-- |
-- Module      : Yukibot.Backend
-- Copyright   : (c) 2016 Michael Walker
-- License     : MIT
-- Stability   : experimental
-- Portability : portable
module Yukibot.Backend
  ( -- * Starting and stopping
    BackendHandle
  , startBackend
  , stopBackend
  , awaitStart
  , awaitStop
  -- ** STM
  , stopBackendSTM
  , awaitStartSTM
  , awaitStopSTM
  , hasStartedSTM
  , hasStoppedSTM

  -- * Interaction
  , BackendTerminatedException(..)
  , Action(..)
  , sendAction
  -- ** STM
  , sendActionSTM

  -- * Miscellaneous
  , describeBackend

  -- * For library authors
  , Backend(..)
  ) where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Monad (void, when)
import Control.Monad.Catch (throwM)
import Data.Text (Text)

import Yukibot.Types

-------------------------------------------------------------------------------
-- Starting and stopping

-- | Start executing a backend in another thread.
--
-- This will return immediately. If you want to block until the
-- backend is ready, see 'awaitStart'.
startBackend :: (Event channel user -> IO ())
  -- ^ Process received events
  -> Backend channel user
  -> IO (BackendHandle channel user)
startBackend onReceive b@(Backend setup exec _) = do
  h <- createHandle b
  forkAndRunBackend h (setup $ \ef -> onReceive =<< ef h) (exec $ msgQueue h)
  pure h

-- | Tell a backend to terminate. If the backend has already
-- terminated, throws 'BackendTerminatedException'.
--
-- This will return immediately, and it is possible that messages from
-- the backend will be received between calling this function and it
-- terminating. If you want to block until the backend is closed, see
-- 'awaitStop'.
stopBackend :: BackendHandle channel user -> IO ()
stopBackend = atomically . stopBackendSTM

-- | STM variant of 'stopBackend'.
stopBackendSTM :: BackendHandle channel user -> STM ()
stopBackendSTM b = sendActionSTM b Terminate

-- | Block until the backend is initialised. If the backend has
-- terminated, or terminates while waiting, this unblocks and throws
-- 'BackendTerminatedException'.
awaitStart :: BackendHandle channel user -> IO ()
awaitStart = atomically . awaitStartSTM

-- | STM variant of 'awaitStart'.
awaitStartSTM :: BackendHandle channel user -> STM ()
awaitStartSTM b = do
  throwOnStop b
  check =<< hasStartedSTM b

-- | Block until the backend terminates. This never throws
-- 'BackendTerminatedException'.
awaitStop :: BackendHandle channel user -> IO ()
awaitStop = atomically . awaitStopSTM

-- | STM variant of 'awaitStop'.
awaitStopSTM :: BackendHandle channel user -> STM ()
awaitStopSTM b = check =<< hasStoppedSTM b

-- | Check if the backend has finished its initialisation and entered
-- the main loop.
hasStartedSTM :: BackendHandle channel user -> STM Bool
hasStartedSTM = readTVar . hasStarted

-- | Check if the backend has terminated.
hasStoppedSTM :: BackendHandle channel user -> STM Bool
hasStoppedSTM = readTVar . hasStopped

-------------------------------------------------------------------------------
-- Interaction

-- | Instruct the backend to perform an action. If the backend has
-- terminated, throws 'BackendTerminatedException'.
--
-- Note: @sendAction b Terminate@ is exactly the same as @stopBackend b@
sendAction :: BackendHandle channel user -> Action channel user -> IO ()
sendAction b = atomically . sendActionSTM b

-- | STM variant of 'sendAction'.
sendActionSTM :: BackendHandle channel user -> Action channel user -> STM ()
sendActionSTM b a = do
  throwOnStop b
  writeTQueue (msgQueue b) a

-------------------------------------------------------------------------------
-- Miscellaneous

-- | Return a textual description of a backend
describeBackend :: BackendHandle channel user -> Text
describeBackend = description

-------------------------------------------------------------------------------
-- Internal

-- | Create a new 'BackendHandle'.
createHandle :: Backend channel user -> IO (BackendHandle channel user)
createHandle b = atomically $ do
  queue    <- newTQueue
  startvar <- newTVar False
  stopvar  <- newTVar False

  pure BackendHandle { msgQueue = queue
                     , hasStarted = startvar
                     , hasStopped = stopvar
                     , description = describe b
                     }

-- | Initialise and run a backend in a new thread.
forkAndRunBackend :: BackendHandle channel user -> IO a -> (a -> IO ()) -> IO ()
forkAndRunBackend h setup exec = void . forkIO $ do
  a <- setup
  atomically $ writeTVar (hasStarted h) True
  exec a
  atomically $ writeTVar (hasStopped h) True

-- | Throw a 'BackendTerminatedException' if it has stopped.
throwOnStop :: BackendHandle channel user -> STM ()
throwOnStop b = do
  stopped <- hasStoppedSTM b
  when stopped (throwM BackendTerminatedException)
