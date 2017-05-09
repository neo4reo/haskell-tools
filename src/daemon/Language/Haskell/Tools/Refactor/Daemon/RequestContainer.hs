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
                     , content_flag :: MVar ()
                     }
mkRequestContainer :: IO RequestContainer
mkRequestContainer = RequestContainer <$> newMVar ([],[]) <*> newEmptyMVar

getRequests :: RequestContainer -> IO ([ClientMessage],[FilePath])
getRequests (RequestContainer {..}) = do
    putStrLn "getRequests: take content flag"
    takeMVar content_flag
    putStrLn "getRequests: take content"
    a <- modifyMVarMasked content $ \(cml,fs) -> return (([],[]), (cml,fs))
    putStrLn "getRequests: content release done"
    return a


putRequest :: RequestContainer -> ClientMessage -> IO ()
putRequest (RequestContainer {..}) cm = do
    putStrLn "putRequest: put content"
    a <- modifyMVarMasked_ content $ \ (cml, fs) -> do
      when (null cml && null fs) $ putMVar content_flag ()
      return (cml++[cm], fs)
    putStrLn "putRequest: content release done"
    return a

putChangedFiles :: RequestContainer -> [FilePath] -> IO ()
putChangedFiles (RequestContainer {..}) fs = do
  putStrLn "putChangedFiles: put content"
  a <- modifyMVarMasked_ content $ \ (cml, fsl) -> do
    when (null cml && null fsl) $ putMVar content_flag ()
    return (cml, fsl ++ fs)
  putStrLn "putChangedFiles: content release done"
  return a
