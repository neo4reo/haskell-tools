{-# LANGUAGE ScopedTypeVariables
           , OverloadedStrings
           , DeriveGeneric
           , LambdaCase
           , TemplateHaskell
           , FlexibleContexts
           , TupleSections
           , RecordWildCards
           #-}
module Language.Haskell.Tools.Refactor.Daemon.RequestContainer where

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
import Language.Haskell.Tools.Refactor.GetModules
import Language.Haskell.Tools.Refactor.Perform
import Language.Haskell.Tools.Refactor.Prepare
import Language.Haskell.Tools.Refactor.RefactorBase
import Language.Haskell.Tools.Refactor.Session

import Debug.Trace



data RequestContainer
  = RequestContainer { content :: MVar ([ClientMessage],[FilePath])
                     , content_lock :: MVar ()
                     }
mkRequestContainer :: IO RequestContainer
mkRequestContainer = RequestContainer <$> newEmptyMVar <*> (newMVar ())

getRequests :: RequestContainer -> IO ([ClientMessage],[FilePath])
getRequests (RequestContainer {..}) = do
    takeMVar content_lock
    c <- takeMVar content
    putMVar content_lock ()
    return c

putRequest :: RequestContainer -> ClientMessage -> IO ()
putRequest (RequestContainer {..}) cm = do
    takeMVar content_lock
    b <- tryPutMVar content ([cm],[])
    if b then return () else modifyMVarMasked_ content $ \ (cml, fs) -> return (cml++[cm], fs)
    putMVar content_lock ()

putChangedFiles :: RequestContainer -> [FilePath] -> IO ()
putChangedFiles (RequestContainer {..}) fs = do
    takeMVar content_lock
    b <- tryPutMVar content ([],fs)
    if b then return () else modifyMVarMasked_ content $ \ (cml, fsl) -> return (cml, fsl ++ fs)
    putMVar content_lock ()

