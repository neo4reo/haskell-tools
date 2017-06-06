
{-# LANGUAGE ScopedTypeVariables
           , OverloadedStrings
           , DeriveGeneric
           , LambdaCase
           , TemplateHaskell
           , FlexibleContexts
           , TupleSections
           , RecordWildCards
           , RecursiveDo
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
mkSystemInterface prot sock = InitSystem prot sock  <$> (return $ logLn "init interface: end socket")


-- | spawn socket request handler
spawnSReq :: SystemInterface -> MergeInterface -> IO SReqInterface
spawnSReq si merge = do
    --reqChan <- newMVar []
    accMVar <- newMVar BS.empty
    tid <- forkIO $ forever $ do
        acc <- takeMVar accMVar
        logLn "sreq: wait for socket.recv"
        received <- recv (si ^. siSocket) 2048
        logLn $ "sreq: received data: " ++ show received
        let raw = BS.concat [acc, received]
            process raw_msg = case decode raw_msg of
                (Just msg) -> logLn ("sreq: send new message to merge: " ++ show msg)>> (merge ^. newRequest) msg >> return Nothing --putMVarChan reqChan msg
                Nothing    -> return (Just raw_msg) -- next $ encode $ ErrorMessage $ "MALFORMED MESSAGE: " ++ unpack mess
            loop rawData = do
                case rawData of
                    [] -> return ()
--                    [new_acc] -> do
--                        putMVar accMVar new_acc
                    (raw_msg:other_msgs) -> do
                        o <- process raw_msg
                        case o of
                            Nothing -> loop other_msgs
                            (Just other) -> logLn ("sreq: unparsable content: " ++ show raw_msg) >> putMVar accMVar other --new_acc
        loop (BS.split '\n' raw)
        when (not $ BS.null received) $ do
            logLn "sreq: end socket"
            si ^. endSocketConnectionNotify
            -- join $ readMVar (si ^. endSocketConnectionNotify)

    return SReqInterface { {-_sockReq = readMVarChan reqChan
                         , _sockReqAll = readAllMVarChan reqChan
                         , -}_shutdownSReq = killThread tid
                         }

-- | spawn socket response handler
spawnSRes :: Socket -> IO SResInterface
spawnSRes sock = do
    resMVar <- newEmptyMVar
    tid <- forkIO $ forever $ do
        logLn "sres: try take a message from merge"
        msg <- takeMVar resMVar
        logLn "sres: received a message from merge"
        sendAll sock (BS.snoc (encode msg) '\n')
        logLn ("sres: send a message over socket connection: " ++ show msg)

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
                       , -}_shutdownFS = killThread tid
                       }


-- | spawn communication chanel switch
spawnMerge :: SystemInterface -> SResInterface -> IO MergeInterface
spawnMerge si sres = do
    reqMsgMVar <- newEmptyMVar
    resMsgMVar <- newEmptyMVar
    finishMVar <- newMVar False
    rc <- mkRequestContainer
    tid <- forkIO $ forever $ do
            logLn "merge: before getRequests"
            (cls,fps) <- getRequests rc
            logLn $ "merge: after getRequests: " ++ show cls
            let sendMsg  = putMVar reqMsgMVar
                dropMVar = (>> return ()) . takeMVar
                loopWhenNotFinished :: (ResponseMsg -> IO ()) -> IO ()
                loopWhenNotFinished m = do
                    logLn "loop: in"
                    logLn "loop: try take a msg from work"
                    msg <- takeMVar resMsgMVar
                    logLn "loop: receive msg from work"
                    case msg of
                        (Just res) -> logLn "loop: just" >> m res >> loopWhenNotFinished m
                        Nothing    -> logLn "loop: nothing" >> return ()
--                    logLn $ "loop(-f): f:" ++ show f
--                    if f
--                      then (logLn "loop(-f): then") >> modifyMVarMasked_ finishMVar (\ _ -> (logLn "loop(-f): lock") >> return False) >> return ()
--                      else (logLn "loop(-f): else") >> m >> (logLn "loop(-f): rec") >> loopWhenNotFinished m
                    logLn "loop: end"
            let doNothing _ = return ()
            case (si ^. refactoringProtocol, length fps > 0) of
              (SafeRefactoringProtocol, True)   -> do
                    logLn "merge: safe, fps"
                    sendMsg (ReLoad fps [])
                    loopWhenNotFinished $ doNothing -- dropMVar resMsgMVar
              (SafeRefactoringProtocol, False)  -> do
                    logLn "merge: safe, no fps"
                    forM_ (takeWhile ((/= RefactorMsgType) . msgType) cls) $ \ msg -> do
                        logLn ("merge: send request to work: " ++ show msg)
                        sendMsg msg
                        logLn "merge: receive responses"
                        loopWhenNotFinished $ \ res -> do
                            -- logLn "merge: try take a response from work"
                            -- res <- takeMVar resMsgMVar
                            logLn ("merge: receive a message and send it to sres: " ++ show res)
                            (sres ^. sockRes) res
              (UnsafeRefactoringProtocol, True) -> do
                    logLn "merge: unsafe, fps"
                    sendMsg (ReLoad fps [])
                    loopWhenNotFinished $ doNothing -- dropMVar resMsgMVar
              (UnsafeRefactoringProtocol, False) -> forM_ cls $ \ cl -> do
                    logLn "merge: unsafe, no fps"
                    sendMsg cl
                    loopWhenNotFinished $ \ res -> do
                        -- res <- takeMVar resMsgMVar
                        (sres ^. sockRes) res
            logLn "merge: request handling done"
    return MergeInterface { _request = takeMVar reqMsgMVar
                          , _response = putMVar resMsgMVar . Just
                          , _newRequest = putRequest rc
                          , _workFinish = putMVar resMsgMVar Nothing -- modifyMVarMasked_ finishMVar (\ _ -> return True) >> return ()
                          , _newFsChanges = putChangedFiles rc
                          , _shutdownMerge = killThread tid
                          }


-- | spawn worker
spawnWork :: ClientMessageHandler -> IO () -> Session -> MVar DaemonSessionState -> MergeInterface -> FSInterface -> IO WorkInterface
spawnWork clh shutdown ghcSess daemonState merge fs = do
    exitingMVar <- newMVar False
    tid <- forkIO $ forever $ do
        logLn $ "work: before request"
        msg <- (merge ^. request)
        logLn $ "work: after request"
        exiting <- modifyMVar daemonState (\st -> swap <$> reflectGhc (runStateT (clh shutdown fs (merge ^. response) msg) st) ghcSess)
        logLn $ "work: client message handled, continue: " ++ show exiting
        modifyMVarMasked_ exitingMVar (\ _ -> return exiting)
        logLn $ "work: finish"
        merge ^. workFinish
        logLn $ "work: work cycle done"
    return WorkInterface { _shutdownWork = killThread tid
                         , _exitingFlag = readMVar exitingMVar
                         }

buildSystem :: ClientMessageHandler -> (SystemInterface -> IO ()) -> Session -> MVar DaemonSessionState -> RefactoringProtocol -> Socket -> IO SystemInterface
buildSystem clh shutdown session daemonState prot sock = mdo
  waitForShutdownMVar <- newEmptyMVar
  si' <- mkSystemInterface prot sock
  let endSCN = logLn "interface: end socket connection" >> putMVar waitForShutdownMVar () -- si ^. endSocketConnectionNotify
      si = si' {_endSocketConnectionNotify = endSCN }
  _sresI <- spawnSRes sock
  _mergeI <- spawnMerge si _sresI
  _sreqI <- spawnSReq si _mergeI
  _fsI <- spawnFS _mergeI
  _workI <- spawnWork clh (shutdown si') session daemonState _mergeI _fsI

  let _refactoringProtocol = prot
      _siSocket            = sock
      _endSocketConnectionNotify = endSCN
      _waitForShutdown     = logLn "interface: wf before" >> takeMVar waitForShutdownMVar >> putMVar waitForShutdownMVar () >> logLn "interface: wf after"
      _shutdownSystem      = void $ forkIO $ do
          putMVar waitForShutdownMVar ()
          _shutdownSReq _sreqI
          _shutdownSRes _sresI
          _shutdownFS _fsI
          _shutdownMerge _mergeI
          _shutdownWork _workI
  si'' <- return SystemInterface {..}
  return si''

{-
shutdownSystem :: SystemInterface -> IO ()
shutdownSystem (InitSystem {}) = error "shutdownSystem on InitSystem"
shutdownSystem si = do logLn "shutdownSystem"
                       void $ forkIO $ do fromJust $ si ^? (sreqI & shutdownSReq)
                                          fromJust $ si ^? (sresI & shutdownSRes)
                                          fromJust $ si ^? (fsI & shutdownFS)
                                          fromJust $ si ^? (mergeI & shutdownMerge)
                                          fromJust $ si ^? (workI & shutdownWork)
-}