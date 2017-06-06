
{-# LANGUAGE ScopedTypeVariables
           , OverloadedStrings
           , DeriveGeneric
           , LambdaCase
           , TemplateHaskell
           , FlexibleContexts
           , TupleSections
           , RecordWildCards
           #-}
module Language.Haskell.Tools.Refactor.Daemon.Logger where

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
import Language.Haskell.Tools.Refactor.Daemon.Representation

import Debug.Trace


type ModuleName = String

logText :: LogLevel -> LogClass -> ModuleName -> String -> String
logText ll lc mn str = "{" ++ show ll ++ ":" ++ show lc ++ "}:" ++ mn ++ ": " ++ str

log :: (MonadIO m) => Config -> LogLevel -> LogClass -> ModuleName -> String -> m ()
log (Config {logmode = NoLoggingMode}) _ _ _ _ = return ()
log (Config {logmode = StdOutputLogMode}) ll lc mn str = liftIO (putStrLn (logText ll lc mn str))

manlog :: (MonadIO m) => Config -> LogLevel -> ModuleName -> String -> m ()
manlog c ll mn str = log c ll ManagementLogClass mn str

iolog :: (MonadIO m) => Config -> LogLevel -> ModuleName -> String -> m ()
iolog c ll mn str = log c ll IOLogClass mn str

ipclog :: (MonadIO m) => Config -> LogLevel -> ModuleName -> String -> m ()
ipclog c ll mn str = log c ll InterProcessCommunicationLogClass mn str

olog :: (MonadIO m) => Config -> LogLevel -> ModuleName -> String -> m ()
olog c ll mn str = log c ll OtherLogClass mn str
