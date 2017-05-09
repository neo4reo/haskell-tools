{-# LANGUAGE ScopedTypeVariables
           , OverloadedStrings
           , DeriveGeneric
           , LambdaCase
           , TemplateHaskell
           , FlexibleContexts
           , TupleSections
           , RecordWildCards
           #-}
module Language.Haskell.Tools.Refactor.Daemon.Representation where

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
import Language.Haskell.Tools.Refactor.GetModules
import Language.Haskell.Tools.Refactor.Perform
import Language.Haskell.Tools.Refactor.Prepare
import Language.Haskell.Tools.Refactor.RefactorBase
import Language.Haskell.Tools.Refactor.Session

import Debug.Trace


data ClientMessage
  = KeepAlive
  | SetPackageDB { pkgDB :: PackageDB }
  | AddPackages { addedPathes :: [FilePath] }
  | RemovePackages { removedPathes :: [FilePath] }
  | PerformRefactoring { refactoring :: String
                       , modulePath :: FilePath
                       , editorSelection :: String
                       , details :: [String]
                       }
  | Stop
  | Disconnect
  | ReLoad { changedModules :: [FilePath]
           , removedModules :: [FilePath]
           }
  deriving (Show, Generic)

instance FromJSON ClientMessage

data ResponseMsg
  = KeepAliveResponse
  | ErrorMessage { errorMsg :: String }
  | CompilationProblem { errorMarkers :: [(SrcSpan, String)] }
  | ModulesChanged { undoChanges :: [UndoRefactor] }
  | LoadedModules { loadedModules :: [(FilePath, String)] }
  | LoadingModules { modulesToLoad :: [FilePath] }
  | Disconnected
  deriving (Show, Generic)

instance ToJSON ResponseMsg

instance ToJSON SrcSpan where
  toJSON (RealSrcSpan sp) = object [ "file" A..= unpackFS (srcSpanFile sp)
                                   , "startRow" A..= srcLocLine (realSrcSpanStart sp)
                                   , "startCol" A..= srcLocCol (realSrcSpanStart sp)
                                   , "endRow" A..= srcLocLine (realSrcSpanEnd sp)
                                   , "endCol" A..= srcLocCol (realSrcSpanEnd sp)
                                   ]
  toJSON _ = Null

data UndoRefactor = RemoveAdded { undoRemovePath :: FilePath }
                  | RestoreRemoved { undoRestorePath :: FilePath
                                   , undoRestoreContents :: String
                                   }
                  | UndoChanges { undoChangedPath :: FilePath
                                , undoDiff :: FileDiff
                                }
  deriving (Show, Generic)




data LogLevel
  = DebugLogLevel
  | InfoLogLevel
  | WanLogLevel
  | ErrorLogLevel
  | CriticalLogLevel
  deriving (Show, Generic)

instance ToJSON LogLevel
instance FromJSON LogLevel

data LogClass
  = ManagementLogClass
  | IOLogClass
  | InterProcessCommunicationLogClass
  | OtherLogClass
  deriving (Show, Generic)

instance ToJSON LogClass
instance FromJSON LogClass

data LogMode
  = NoLoggingMode
  | StdOutputLogMode
  deriving (Show, Generic)

instance ToJSON LogMode
instance FromJSON LogMode

data Config
  = Config { loglevel :: LogLevel
           , logclass :: LogClass
           , logmode  :: LogMode
           }
  deriving (Show, Generic)

instance ToJSON Config
instance FromJSON Config





data SReqInterface
  = SReqInterface { _shutdownSReq :: IO ()
                  }


data SResInterface
  = SResInterface { _sockRes :: ResponseMsg -> IO ()
                  , _shutdownSRes :: IO ()
                  }


data FSRegistration
  = FSRegistration { _fsregistration :: FilePath }
  | FSUnregistration { _fsunregistration :: FilePath }


data FSInterface
  = FSInterface { _filePathRegister :: FSRegistration -> IO ()
                , _shutdownFS :: IO ()
                }


data MergeInterface
  = MergeInterface { _request :: IO ClientMessage          -- call: work -> merge
                   , _response :: ResponseMsg -> IO ()     -- call: work -> merge
                   , _workFinish :: IO ()                  -- call: work -> merge
                   , _newRequest :: ClientMessage -> IO () -- call: sreq -> merge
                   , _newFsChanges :: [FilePath] -> IO ()  -- call: fs -> merge
                   , _shutdownMerge :: IO ()               -- call: main/spawner -> merge
                   }


data WorkInterface
  = WorkInterface { _shutdownWork :: IO ()                 -- call: main/spawner -> work
                  , _exitingFlag :: IO Bool
                  }




data SystemInterface
  = InitSystem { _refactoringProtocol :: RefactoringProtocol
               , _siSocket :: Socket
               , _endSocketConnectionNotify :: MVar (IO ())
               }
  | SystemInterface { _refactoringProtocol :: RefactoringProtocol
                    , _siSocket :: Socket
                    , _endSocketConnectionNotify :: MVar (IO ())
                    , _waitForShutdown :: IO ()
                    , _shutdownSystem :: IO ()
                    , _sreqI :: SReqInterface
                    , _sresI :: SResInterface
                    , _fsI :: FSInterface
                    , _mergeI :: MergeInterface
                    , _workI :: WorkInterface
                    }


type ClientMessageHandler = IO () -> FSInterface -> (ResponseMsg -> IO ()) -> ClientMessage -> StateT DaemonSessionState Ghc Bool

type FileDiff = [(Int, Int, String)]

data RefactoringProtocol
  = SafeRefactoringProtocol
  | UnsafeRefactoringProtocol


instance ToJSON UndoRefactor
makeReferences ''SReqInterface
makeReferences ''SResInterface
makeReferences ''FSRegistration
makeReferences ''FSInterface
makeReferences ''MergeInterface
makeReferences ''WorkInterface
makeReferences ''SystemInterface