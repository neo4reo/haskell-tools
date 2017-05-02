
{-# LANGUAGE ScopedTypeVariables
           , OverloadedStrings
           , DeriveGeneric
           , LambdaCase
           , TemplateHaskell
           , FlexibleContexts
           , TupleSections
           , RecordWildCards
           #-}
module Language.Haskell.Tools.Refactor.Daemon.DaemonThreads where

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
import Language.Haskell.Tools.Refactor.Daemon.RequestContainer
import Language.Haskell.Tools.Refactor.GetModules
import Language.Haskell.Tools.Refactor.Perform
import Language.Haskell.Tools.Refactor.Prepare
import Language.Haskell.Tools.Refactor.RefactorBase
import Language.Haskell.Tools.Refactor.Session

import Debug.Trace





mkSystemInterface :: RefactoringProtocol -> Socket -> IO SystemInterface
mkSystemInterface prot sock = InitSystem prot sock <$> (newMVar (return ()))


-- | spawn socket request handler
spawnSReq :: SystemInterface -> MergeInterface -> IO SReqInterface
spawnSReq si merge = do
    --reqChan <- newMVar []
    accMVar <- newMVar BS.empty
    tid <- forkIO $ forever $ do
        acc <- takeMVar accMVar
        received <- recv (si ^. siSocket) 2048
        let raw = BS.concat [acc, received]
            process raw_msg = case decode raw_msg of
                (Just msg) -> (merge ^. newRequest) msg --putMVarChan reqChan msg
                Nothing    -> return () -- next $ encode $ ErrorMessage $ "MALFORMED MESSAGE: " ++ unpack mess
            loop rawData = do
                case rawData of
                    [] -> return ()
                    [new_acc] -> do
                        putMVar accMVar new_acc
                    (raw_msg:other_msgs) -> do
                        process raw_msg
                        loop other_msgs
        when (not $ BS.null received) (join $ readMVar (si ^. endSocketConnectionNotify))
        loop (BS.split '\n' raw)

    return SReqInterface { {-_sockReq = readMVarChan reqChan
                         , _sockReqAll = readAllMVarChan reqChan
                         , -}_shutdownSReq = killThread tid
                         }

-- | spawn socket response handler
spawnSRes :: Socket -> IO SResInterface
spawnSRes sock = do
    resMVar <- newEmptyMVar
    tid <- forkIO $ forever $ do
        msg <- takeMVar resMVar
        sendAll sock (BS.snoc (encode msg) '\n')

    return SResInterface { _sockRes = putMVar resMVar
                         , _shutdownSRes = killThread tid
                         }

-- | spawn file system change notifying handler
spawnFS :: MergeInterface -> IO FSInterface
spawnFS merge = do
    state <- newMVar Map.empty
    regChan <- newChan
    cndMVar <- newMVar (ReLoad [] [])
    let process e = case e of
          (FS.Added fp _) -> return ()
          (FS.Modified fp _) -> (merge ^. newFsChanges) [fp] -- (modified fp) -- changedFiles (modified fp)-- modifyMVarMasked_ cndMVar (modified fp)
          (FS.Removed fp _) -> (merge ^. newFsChanges) [fp] -- (removed fp) -- changedFiles (removed fp) -- modifyMVarMasked_ cndMVar (removed fp)
        modified fp (ReLoad ml dl) = return (ReLoad (nub (fp:ml)) dl)
        removed fp (ReLoad ml dl) = return (ReLoad ml (nub (fp:dl)))
        stop fp m = case Map.lookup fp m of
          Nothing -> return m
          (Just mng) -> do
            FS.stopManager mng
            return (Map.delete fp m)
    tid <- forkIO $ forever $ do
        reg <- readChan regChan
        case reg of
          (FSRegistration fp) -> do
              mng <- FS.startManager
              modifyMVarMasked_ state (return . Map.insert fp mng)
              FS.watchTree
                  mng
                  fp
                  (const True)
                  process
              return ()
          (FSUnregistration fp) -> modifyMVarMasked_ state (stop fp)

    return FSInterface { _filePathRegister = writeChan regChan
                       , {-_changedFiles = readMVar cndMVar
                       , -}_shutdownFS = undefined
                       }

-- | spawn communication chanel switch
spawnMerge :: SystemInterface -> SResInterface -> IO MergeInterface
spawnMerge si sres = do
    reqMsgMVar <- newEmptyMVar
    resMsgMVar <- newEmptyMVar
    finishMVar <- newMVar False
    rc <- mkRequestContainer
    tid <- forkIO $ forever $ do
            putStrLn "before getRequests"
            (cls,fps) <- getRequests rc
            putStrLn $ "after getRequests: " ++ show cls
            let sendMsg  = putMVar reqMsgMVar
                dropMVar = (>> return ()) . takeMVar
                loopWhenNotFinished :: IO () -> IO ()
                loopWhenNotFinished m = do
                    f <- readMVar finishMVar
                    if f
                      then modifyMVarMasked_ finishMVar (\ _ -> return False) >> return ()
                      else m >> loopWhenNotFinished m
            case (si ^. refactoringProtocol, length fps > 0) of
              (SafeRefactoringProtocol, True)   -> do
                    sendMsg (ReLoad fps [])
                    loopWhenNotFinished $ dropMVar resMsgMVar
              (SafeRefactoringProtocol, False)  -> do
                    sendMsg (head cls)
                    loopWhenNotFinished $ do
                        res <- takeMVar resMsgMVar
                        (sres ^. sockRes) res
              (UnsafeRefactoringProtocol, True) -> do
                    sendMsg (ReLoad fps [])
                    loopWhenNotFinished $ dropMVar resMsgMVar
              (UnsafeRefactoringProtocol, True) -> forM_ cls $ \ cl -> do
                    sendMsg cl
                    loopWhenNotFinished $ do
                        res <- takeMVar resMsgMVar
                        (sres ^. sockRes) res
    return MergeInterface { _request = takeMVar reqMsgMVar
                          , _response = putMVar resMsgMVar
                          , _newRequest = putRequest rc
                          , _workFinish = takeMVar finishMVar >> putMVar finishMVar True
                          , _newFsChanges = putChangedFiles rc
                          , _shutdownMerge = killThread tid
                          }


-- | spawn worker
spawnWork :: ClientMessageHandler -> Session -> MVar DaemonSessionState -> MergeInterface -> FSInterface -> IO WorkInterface
spawnWork clh ghcSess daemonState merge fs = do
    exitingMVar <- newMVar False
    tid <- forkIO $ forever $ do
        msg <- (merge ^. request)
        exiting <- modifyMVar daemonState (\st -> swap <$> reflectGhc (runStateT (clh fs (merge ^. response) msg) st) ghcSess)
        putStrLn $ "client message handled, continue: " ++ show exiting
        modifyMVarMasked_ exitingMVar (\ _ -> return exiting)
        merge ^. workFinish
        putStrLn $ "work cycle done"
    return WorkInterface { _shutdownWork = killThread tid
                         , _exitingFlag = readMVar exitingMVar
                         }

buildSystem :: ClientMessageHandler -> Session -> MVar DaemonSessionState -> RefactoringProtocol -> Socket -> IO SystemInterface
buildSystem clh session daemonState prot sock = do
  si <- mkSystemInterface prot sock
  _sresI <- spawnSRes sock
  _mergeI <- spawnMerge si _sresI
  _sreqI <- spawnSReq si _mergeI
  _fsI <- spawnFS _mergeI
  _workI <- spawnWork clh session daemonState _mergeI _fsI

  let _refactoringProtocol = prot
      _siSocket            = sock
      _endSocketConnectionNotify = si ^. endSocketConnectionNotify
  return SystemInterface {..}


shutdownSystem :: SystemInterface -> IO ()
shutdownSystem (InitSystem {}) = error "shutdownSystem on InitSystem"
shutdownSystem si = do putStrLn "shutdownSystem"
                       void $ forkIO $ do fromJust $ si ^? (sreqI & shutdownSReq)
                                          fromJust $ si ^? (sresI & shutdownSRes)
                                          fromJust $ si ^? (fsI & shutdownFS)
                                          fromJust $ si ^? (mergeI & shutdownMerge)
                                          fromJust $ si ^? (workI & shutdownWork)
