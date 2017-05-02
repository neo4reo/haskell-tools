{-# LANGUAGE ScopedTypeVariables
           , OverloadedStrings
           , DeriveGeneric
           , LambdaCase
           , TemplateHaskell
           , FlexibleContexts
           , TupleSections
           , RecordWildCards
           #-}
module Language.Haskell.Tools.Refactor.Daemon where

import Control.Applicative ((<|>))
import Control.Concurrent
import Control.Concurrent.MVar
import Control.Concurrent.Chan
import Control.Exception
import Control.Monad
import Control.Monad.State
import Control.Reference hiding (modifyMVarMasked_)
import qualified Data.Aeson as A ((.=))
import Data.Aeson hiding ((.=))
import Data.ByteString.Lazy.Char8 (ByteString)
import Data.ByteString.Lazy.Char8 (unpack)
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified Data.ByteString.Char8 as StrictBS
import Data.IORef
import Data.List hiding (insert)
import qualified Data.Map as Map
import Data.Maybe
import Data.Tuple
import GHC.Generics
import Network.Socket hiding (send, sendTo, recv, recvFrom, KeepAlive)
import Network.Socket.ByteString.Lazy
import System.Directory
import System.Environment
import System.IO
import qualified System.FSNotify as FS
import Data.Algorithm.Diff
import Data.Either

import Bag
import DynFlags
import ErrUtils
import FastString (unpackFS)
import GHC hiding (loadModule)
import GHC.Paths ( libdir )
import GhcMonad (GhcMonad(..), Session(..), reflectGhc, modifySession)
import HscTypes (hsc_mod_graph)
import Packages
import SrcLoc

import Language.Haskell.Tools.AST
import Language.Haskell.Tools.PrettyPrint
import Language.Haskell.Tools.Refactor.Daemon.PackageDB
import Language.Haskell.Tools.Refactor.Daemon.State
import Language.Haskell.Tools.Refactor.Daemon.Representation
import Language.Haskell.Tools.Refactor.Daemon.DaemonThreads
import Language.Haskell.Tools.Refactor.Daemon.RequestContainer
import Language.Haskell.Tools.Refactor.Daemon.HandleClientMessage
import Language.Haskell.Tools.Refactor.Daemon.Utils
import Language.Haskell.Tools.Refactor.GetModules
import Language.Haskell.Tools.Refactor.Perform
import Language.Haskell.Tools.Refactor.Prepare
import Language.Haskell.Tools.Refactor.RefactorBase
import Language.Haskell.Tools.Refactor.Session

import Debug.Trace




-- TODO: handle boot files

runDaemonCLI :: IO ()
runDaemonCLI = getArgs >>= runDaemon

runDaemon :: [String] -> IO ()
runDaemon args = withSocketsDo $
    do let finalArgs = args ++ drop (length args) defaultArgs
           isSilent = read (finalArgs !! 1)
       hSetBuffering stdout LineBuffering
       hSetBuffering stderr LineBuffering
       when (not isSilent) $ putStrLn $ "Starting Haskell Tools daemon"
       sock <- socket AF_INET Stream 0
       setSocketOption sock ReuseAddr 1
       when (not isSilent) $ putStrLn $ "Listening on port " ++ finalArgs !! 0
       bind sock (SockAddrInet (read (finalArgs !! 0)) iNADDR_ANY)
       listen sock 1
       si <- clientLoop isSilent sock
       shutdownSystem si

defaultArgs :: [String]
defaultArgs = ["4123", "True"]

clientLoop :: Bool -> Socket -> IO SystemInterface
clientLoop isSilent sock
  = do when (not isSilent) $ putStrLn $ "Starting client loop"
       (conn,_) <- accept sock
       ghcSess <- initGhcSession
       state <- newMVar initSession
       si <- buildSystem handleClientMessage ghcSess state SafeRefactoringProtocol conn
       sessionData <- readMVar state
       when (not (sessionData ^. exiting))
         $ void $ clientLoop isSilent sock
       return si

-- serverLoop :: Bool -> Session -> MVar DaemonSessionState -> Socket -> IO ()
-- serverLoop isSilent ghcSess state sock =
--     do msg <- recv sock 2048
--        when (not $ BS.null msg) $ do -- null on TCP means closed connection
--          when (not isSilent) $ putStrLn $ "message received: " ++ show (unpack msg)
--          let msgs = BS.split '\n' msg
--          continue <- forM msgs $ \msg -> respondTo ghcSess state (sendAll sock . (`BS.snoc` '\n')) msg
--          sessionData <- readMVar state
--          when (not (sessionData ^. exiting) && all (== True) continue)
--            $ serverLoop isSilent ghcSess state sock
--   `catch` interrupted
--   where interrupted = \ex -> do
--                         let err = show (ex :: IOException)
--                         when (not isSilent) $ do
--                           putStrLn "Closing down socket"
--                           hPutStrLn stderr $ "Some exception caught: " ++ err

-- respondTo :: Session -> MVar DaemonSessionState -> (ByteString -> IO ()) -> ByteString -> IO Bool
-- respondTo ghcSess state next mess
--   | BS.null mess = return True
--   | otherwise
--   = case decode mess of
--       Nothing -> do next $ encode $ ErrorMessage $ "MALFORMED MESSAGE: " ++ unpack mess
--                     return True
--       Just req -> modifyMVar state (\st -> swap <$> reflectGhc (runStateT (updateClient (next . encode) req) st) ghcSess)
