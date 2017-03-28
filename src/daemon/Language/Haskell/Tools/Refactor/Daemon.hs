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

instance ToJSON UndoRefactor

type FileDiff = [(Int, Int, String)]


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


data RefactoringProtocol
  = SafeRefactoringProtocol
  | UnsafeRefactoringProtocol




data SReqInterface
  = SReqInterface { {-_sockReq :: IO (Maybe ClientMessage)
                  , _sockReqAll :: IO [ClientMessage]
                  , -}_shutdownSReq :: IO ()
                  }
makeReferences ''SReqInterface

data SResInterface
  = SResInterface { _sockRes :: ResponseMsg -> IO ()
                  , _shutdownSRes :: IO ()
                  }
makeReferences ''SResInterface

data FSRegistration
  = FSRegistration { _fsregistration :: FilePath }
  | FSUnregistration { _fsunregistration :: FilePath }
makeReferences ''FSRegistration

data FSInterface
  = FSInterface { _filePathRegister :: FSRegistration -> IO ()
                , {-_changedFiles :: IO ClientMessage
                , -}_shutdownFS :: IO ()
                }
makeReferences ''FSInterface

data MergeInterface
  = MergeInterface { _request :: IO ClientMessage          -- call: work -> merge
                   , _response :: ResponseMsg -> IO ()     -- call: work -> merge
                   , _newRequest :: ClientMessage -> IO () -- call: sreq -> merge
                   , _newFsChanges :: [FilePath] -> IO ()  -- call: fs -> merge
                   , _shutdownMerge :: IO ()               -- call: main/spawner -> merge
                   }
makeReferences ''MergeInterface

data WorkInterface
  = WorkInterface { _shutdownWork :: IO ()                 -- call: main/spawner -> work
                  }
makeReferences ''WorkInterface



data SystemInterface
  = InitSystem { _refactoringProtocol :: RefactoringProtocol
               , _siSocket :: Socket
               , _endSocketConnectionNotify :: MVar (IO ())
               }
  | SystemInterface { _refactoringProtocol :: RefactoringProtocol
                    , _siSocket :: Socket
                    , _endSocketConnectionNotify :: MVar (IO ())
                    , _sreqI :: SReqInterface
                    , _sresI :: SResInterface
                    , _fsI :: FSInterface
                    , _mergeI :: MergeInterface
                    , _workI :: WorkInterface
                    }
makeReferences ''SystemInterface

mkSystemInterface :: RefactoringProtocol -> Socket -> IO SystemInterface
mkSystemInterface prot sock = InitSystem prot sock <$> (newMVar (return ()))


{-
readMVarChan :: MVar [a] -> IO (Maybe a)
readMVarChan mvar = modifyMVarMasked mvar (return . split)
  where
    split [] = ([], Nothing)
    split (x:xs) = (xs, Just x)

readAllMVarChan :: MVar [a] -> IO [a]
readAllMVarChan mvar = modifyMVarMasked mvar (return . ([],))

putMVarChan :: MVar [a] -> a -> IO ()
putMVarChan mvar elem = modifyMVarMasked_ mvar (return . (++[elem]))
-}

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
    rc <- mkRequestContainer
    tid <- forkIO $ forever $ do
--        (ReLoad ml dl) <- (fs ^. changedFiles)
--        if (length ml > 0) || (length dl > 0)
--          then do
--            putMVar reqMsgMVar (ReLoad ml dl)
--            void $ takeMVar resMsgMVar
--          else do
            (cls,fps) <- getRequests rc
            case si ^. refactoringProtocol of
              SafeRefactoringProtocol -> do
                if length fps > 0
                  then void $ do
                    putMVar reqMsgMVar (ReLoad fps [])
                    takeMVar resMsgMVar
                  else void $ do
                    putMVar reqMsgMVar (head cls)
                    res <- takeMVar resMsgMVar
                    (sres ^. sockRes) res
              UnsafeRefactoringProtocol -> do
                if length fps > 0
                  then void $ do
                    putMVar reqMsgMVar (ReLoad fps [])
                    takeMVar resMsgMVar
                  else forM_ cls $ \ cl -> do
                    putMVar reqMsgMVar cl
                    res <- takeMVar resMsgMVar
                    (sres ^. sockRes) res
            return ()
    return MergeInterface { _request = takeMVar reqMsgMVar
                          , _response = putMVar resMsgMVar
                          , _newRequest = putRequest rc
                          , _newFsChanges = putChangedFiles rc
                            -- \ (ReLoad ml dl) -> putChangedFiles rc (ReLoad (nub ml) (nub dl))
                          , _shutdownMerge = killThread tid
                          }


-- | spawn worker
spawnWork :: MergeInterface -> IO WorkInterface
spawnWork merge = do
    tid <- forkIO $ forever $ do
        msg <- (merge ^. request)
        msg' <- undefined
        (merge ^. response) msg'
    return WorkInterface { _shutdownWork = killThread tid
                         }

buildSystem :: RefactoringProtocol -> Socket -> IO SystemInterface
buildSystem prot sock = do
  si <- mkSystemInterface prot sock
  _sresI <- spawnSRes sock
  _mergeI <- spawnMerge si _sresI
  _sreqI <- spawnSReq si _mergeI
  _fsI <- spawnFS _mergeI
  _workI <- spawnWork _mergeI

  let _refactoringProtocol = prot
      _siSocket            = sock
      _endSocketConnectionNotify = si ^. endSocketConnectionNotify
  return SystemInterface {..}

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
       clientLoop isSilent sock

defaultArgs :: [String]
defaultArgs = ["4123", "True"]




clientLoop :: Bool -> Socket -> IO ()
clientLoop isSilent sock
  = do when (not isSilent) $ putStrLn $ "Starting client loop"
       (conn,_) <- accept sock
       ghcSess <- initGhcSession
       state <- newMVar initSession
       serverLoop isSilent ghcSess state conn
       sessionData <- readMVar state
       when (not (sessionData ^. exiting))
         $ clientLoop isSilent sock

serverLoop :: Bool -> Session -> MVar DaemonSessionState -> Socket -> IO ()
serverLoop isSilent ghcSess state sock =
    do msg <- recv sock 2048
       when (not $ BS.null msg) $ do -- null on TCP means closed connection
         when (not isSilent) $ putStrLn $ "message received: " ++ show (unpack msg)
         let msgs = BS.split '\n' msg
         continue <- forM msgs $ \msg -> respondTo ghcSess state (sendAll sock . (`BS.snoc` '\n')) msg
         sessionData <- readMVar state
         when (not (sessionData ^. exiting) && all (== True) continue)
           $ serverLoop isSilent ghcSess state sock
  `catch` interrupted
  where interrupted = \ex -> do
                        let err = show (ex :: IOException)
                        when (not isSilent) $ do
                          putStrLn "Closing down socket"
                          hPutStrLn stderr $ "Some exception caught: " ++ err

respondTo :: Session -> MVar DaemonSessionState -> (ByteString -> IO ()) -> ByteString -> IO Bool
respondTo ghcSess state next mess
  | BS.null mess = return True
  | otherwise
  = case decode mess of
      Nothing -> do next $ encode $ ErrorMessage $ "MALFORMED MESSAGE: " ++ unpack mess
                    return True
      Just req -> modifyMVar state (\st -> swap <$> reflectGhc (runStateT (updateClient (next . encode) req) st) ghcSess)

-- | This function does the real job of acting upon client messages in a stateful environment of a client
updateClient :: (ResponseMsg -> IO ()) -> ClientMessage -> StateT DaemonSessionState Ghc Bool
updateClient resp KeepAlive = liftIO (resp KeepAliveResponse) >> return True
updateClient resp Disconnect = liftIO (resp Disconnected) >> return False
updateClient _ (SetPackageDB pkgDB) = modify (packageDB .= pkgDB) >> return True
updateClient resp (AddPackages packagePathes) = do
    existingMCs <- gets (^. refSessMCs)
    let existing = map ms_mod $ (existingMCs ^? traversal & filtered isTheAdded & mcModules & traversal & modRecMS)
    needToReload <- (filter (\ms -> not $ ms_mod ms `elem` existing))
                      <$> getReachableModules (\_ -> return ()) (\ms -> ms_mod ms `elem` existing)
    modify $ refSessMCs .- filter (not . isTheAdded) -- remove the added package from the database
    forM_ existing $ \mn -> removeTarget (TargetModule (GHC.moduleName mn))
    modifySession (\s -> s { hsc_mod_graph = filter (not . (`elem` existing) . ms_mod) (hsc_mod_graph s) })
    initializePackageDBIfNeeded
    res <- loadPackagesFrom (\ms -> resp (LoadedModules [(getModSumOrig ms, getModSumName ms)]) >> return (getModSumOrig ms))
                            (resp . LoadingModules . map getModSumOrig) packagePathes
    case res of
      Right (modules, ignoredMods) -> do
        mapM_ (reloadModule (\_ -> return ())) needToReload -- don't report consequent reloads (not expected)
        liftIO $ when (not $ null ignoredMods)
                   $ resp $ ErrorMessage
                              $ "The following modules are ignored: "
                                   ++ concat (intersperse ", " ignoredMods)
                                   ++ ". Multiple modules with the same qualified name are not supported."
      Left err -> liftIO $ resp $ either ErrorMessage CompilationProblem (getProblems err)
    return True
  where isTheAdded mc = (mc ^. mcRoot) `elem` packagePathes
        initializePackageDBIfNeeded = do
          pkgDBAlreadySet <- gets (^. packageDBSet)
          when (not pkgDBAlreadySet) $ do
            pkgDB <- gets (^. packageDB)
            pkgDBLocs <- liftIO $ packageDBLocs pkgDB packagePathes
            usePackageDB pkgDBLocs
            modify (packageDBSet .= True)

updateClient _ (RemovePackages packagePathes) = do
    mcs <- gets (^. refSessMCs)
    let existing = map ms_mod (mcs ^? traversal & filtered isRemoved & mcModules & traversal & modRecMS)
    lift $ forM_ existing (\modName -> removeTarget (TargetModule (GHC.moduleName modName)))
    lift $ deregisterDirs (mcs ^? traversal & filtered isRemoved & mcSourceDirs & traversal)
    modify $ refSessMCs .- filter (not . isRemoved)
    modifySession (\s -> s { hsc_mod_graph = filter (not . (`elem` existing) . ms_mod) (hsc_mod_graph s) })
    return True
  where isRemoved mc = (mc ^. mcRoot) `elem` packagePathes

updateClient resp (ReLoad changed removed) =
  do removedMods <- gets (map ms_mod . filter ((`elem` removed) . getModSumOrig) . (^? refSessMCs & traversal & mcModules & traversal & modRecMS))
     lift $ forM_ removedMods (\modName -> removeTarget (TargetModule (GHC.moduleName modName)))
     modify $ refSessMCs & traversal & mcModules
                .- Map.filter (\m -> maybe True (not . (`elem` removed) . getModSumOrig) (m ^? modRecMS))
     modifySession (\s -> s { hsc_mod_graph = filter (not . (`elem` removedMods) . ms_mod) (hsc_mod_graph s) })
     reloadRes <- reloadChangedModules (\ms -> resp (LoadedModules [(getModSumOrig ms, getModSumName ms)]))
                                       (\mss -> resp (LoadingModules (map getModSumOrig mss)))
                                       (\ms -> getModSumOrig ms `elem` changed)
     liftIO $ case reloadRes of Left errs -> resp (either ErrorMessage CompilationProblem (getProblems errs))
                                Right _ -> return ()
     return True

updateClient _ Stop = modify (exiting .= True) >> return False

updateClient resp (PerformRefactoring refact modPath selection args) = do
    (Just actualMod, otherMods) <- getFileMods modPath
    let cmd = analyzeCommand refact (selection:args)
    res <- lift $ performCommand cmd actualMod otherMods
    case res of
      Left err -> liftIO $ resp $ ErrorMessage err
      Right diff -> do changedMods <- applyChanges diff
                       liftIO $ resp $ ModulesChanged (map (either id (\(_,_,ch) -> ch)) changedMods)
                       void $ reloadChanges (map ((^. sfkModuleName) . (\(key,_,_) -> key)) (rights changedMods))
    return True
  where applyChanges changes = do
          forM changes $ \case
            ModuleCreated n m otherM -> do
              mcs <- gets (^. refSessMCs)
              Just (_, otherMR) <- gets (lookupModInSCs otherM . (^. refSessMCs))

              let Just otherMS = otherMR ^? modRecMS
                  Just mc = lookupModuleColl (otherM ^. sfkModuleName) mcs
              modify $ refSessMCs & traversal & filtered (\mc' -> (mc' ^. mcId) == (mc ^. mcId)) & mcModules
                         .- Map.insert (SourceFileKey NormalHs n) (ModuleNotLoaded False)
              otherSrcDir <- liftIO $ getSourceDir otherMS
              let loc = toFileName otherSrcDir n
              liftIO $ withBinaryFile loc WriteMode (`hPutStr` prettyPrint m)
              lift $ addTarget (Target (TargetModule (GHC.mkModuleName n)) True Nothing)
              return $ Right (SourceFileKey NormalHs n, loc, RemoveAdded loc)
            ContentChanged (n,m) -> do
              Just (_, mr) <- gets (lookupModInSCs n . (^. refSessMCs))
              let Just ms = mr ^? modRecMS
              origCont <- liftIO (StrictBS.unpack <$> StrictBS.readFile (getModSumOrig ms))
              let newCont = prettyPrint m
                  undo = createUndo 0 $ getGroupedDiff origCont newCont
                  file = getModSumOrig ms
              liftIO $ withBinaryFile file WriteMode (`hPutStr` newCont)
              return $ Right (n, file, UndoChanges file undo)
            ModuleRemoved mod -> do
              Just (_,m) <- gets (lookupModInSCs (SourceFileKey NormalHs mod) . (^. refSessMCs))
              let modName = GHC.moduleName $ fromJust $ fmap semanticsModule (m ^? typedRecModule) <|> fmap semanticsModule (m ^? renamedRecModule)
              ms <- getModSummary modName
              let file = getModSumOrig ms
              origCont <- liftIO (StrictBS.unpack <$> StrictBS.readFile file)
              lift $ removeTarget (TargetModule modName)
              modify $ (refSessMCs .- removeModule mod)
              liftIO $ removeFile file
              return $ Left $ RestoreRemoved file origCont

        reloadChanges changedMods
          = do reloadRes <- reloadChangedModules (\ms -> resp (LoadedModules [(getModSumOrig ms, getModSumName ms)]))
                                                 (\mss -> resp (LoadingModules (map getModSumOrig mss)))
                                                 (\ms -> modSumName ms `elem` changedMods)
               liftIO $ case reloadRes of Left errs -> resp (either ErrorMessage (ErrorMessage . ("The result of the refactoring contains errors: " ++) . show) (getProblems errs))
                                          Right _ -> return ()



createUndo :: Eq a => Int -> [Diff [a]] -> [(Int, Int, [a])]
createUndo i (Both str _ : rest) = createUndo (i + length str) rest
createUndo i (First rem : Second add : rest)
  = (i, i + length add, rem) : createUndo (i + length add) rest
createUndo i (First rem : rest) = (i, i, rem) : createUndo i rest
createUndo i (Second add : rest)
  = (i, i + length add, []) : createUndo (i + length add) rest
createUndo _ [] = []

initGhcSession :: IO Session
initGhcSession = Session <$> (newIORef =<< runGhc (Just libdir) (initGhcFlags >> getSession))

usePackageDB :: GhcMonad m => [FilePath] -> m ()
usePackageDB [] = return ()
usePackageDB pkgDbLocs
  = do dfs <- getSessionDynFlags
       dfs' <- liftIO $ fmap fst $ initPackages
                 $ dfs { extraPkgConfs = (map PkgConfFile pkgDbLocs ++) . extraPkgConfs dfs
                       , pkgDatabase = Nothing
                       }
       void $ setSessionDynFlags dfs'

getProblems :: RefactorException -> Either String [(SrcSpan, String)]
getProblems (SourceCodeProblem errs) = Right $ map (\err -> (errMsgSpan err, show err)) $ bagToList errs
getProblems other = Left $ displayException other

