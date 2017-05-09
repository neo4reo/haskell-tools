{-# LANGUAGE ScopedTypeVariables
           , OverloadedStrings
           , DeriveGeneric
           , LambdaCase
           , TemplateHaskell
           , FlexibleContexts
           , TupleSections
           , RecordWildCards
           #-}
module Language.Haskell.Tools.Refactor.Daemon.HandleClientMessage where

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
import Language.Haskell.Tools.Refactor.Daemon.Utils
import Language.Haskell.Tools.Refactor.GetModules
import Language.Haskell.Tools.Refactor.Perform
import Language.Haskell.Tools.Refactor.Prepare
import Language.Haskell.Tools.Refactor.RefactorBase
import Language.Haskell.Tools.Refactor.Session

import Debug.Trace



-- | This function does the real job of acting upon client messages in a stateful environment of a client
handleClientMessage :: ClientMessageHandler
handleClientMessage _ _ resp KeepAlive = liftIO (resp KeepAliveResponse) >> return True
handleClientMessage _ _ resp Disconnect = liftIO (resp Disconnected) >> return False
handleClientMessage _ _ _ (SetPackageDB pkgDB) = modify (packageDB .= pkgDB) >> return True
handleClientMessage _ fs resp (AddPackages packagePathes) = do
    liftIO $ forM packagePathes $ (fs ^. filePathRegister) . FSRegistration
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

handleClientMessage _ fs _ (RemovePackages packagePathes) = do
    liftIO $ forM packagePathes $ (fs ^. filePathRegister) . FSUnregistration
    mcs <- gets (^. refSessMCs)
    let existing = map ms_mod (mcs ^? traversal & filtered isRemoved & mcModules & traversal & modRecMS)
    lift $ forM_ existing (\modName -> removeTarget (TargetModule (GHC.moduleName modName)))
    lift $ deregisterDirs (mcs ^? traversal & filtered isRemoved & mcSourceDirs & traversal)
    modify $ refSessMCs .- filter (not . isRemoved)
    modifySession (\s -> s { hsc_mod_graph = filter (not . (`elem` existing) . ms_mod) (hsc_mod_graph s) })
    return True
  where isRemoved mc = (mc ^. mcRoot) `elem` packagePathes

handleClientMessage _ _ resp (ReLoad changed removed) =
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

handleClientMessage shutdown _ _ Stop = do liftIO $ putStrLn "STOP"
                                           modify (exiting .= True) >> (liftIO shutdown) >> return False

handleClientMessage _ _ resp (PerformRefactoring refact modPath selection args) = do
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
