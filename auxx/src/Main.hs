module Main
       ( main
       ) where

import           Universum
import           Unsafe                (unsafeFromJust)

import           Formatting            (sformat, shown, (%))
import           Mockable              (Production, currentTime, runProduction)
import qualified Network.Transport.TCP as TCP (TCPAddr (..))
import qualified System.IO.Temp        as Temp
import           System.Wlog           (logInfo)

import qualified Pos.Client.CLI        as CLI
import           Pos.Communication     (OutSpecs, WorkerSpec)
import           Pos.Core              (Timestamp (..), gdStartTime, genesisData)
import           Pos.DB.DB             (initNodeDBs)
import           Pos.Launcher          (HasConfigurations, NodeParams (..), NodeResources,
                                        bracketNodeResources, loggerBracket, lpConsoleLog,
                                        runNode, runRealBasedMode, withConfigurations)
import           Pos.Network.Types     (NetworkConfig (..), Topology (..),
                                        topologyDequeuePolicy, topologyEnqueuePolicy,
                                        topologyFailurePolicy)
import           Pos.Ssc.SscAlgo       (SscAlgo (GodTossingAlgo))
import           Pos.Txp               (txpGlobalSettings)
import           Pos.Util.CompileInfo  (HasCompileInfo, retrieveCompileTimeInfo,
                                        withCompileInfo)
import           Pos.Util.UserSecret   (usVss)
import           Pos.WorkMode          (EmptyMempoolExt, RealMode)

import           AuxxOptions           (AuxxAction (..), AuxxOptions (..), getAuxxOptions)
import           Mode                  (AuxxContext (..), AuxxMode, CmdCtx (..),
                                        realModeToAuxx)
import           Plugin                (auxxPlugin)
import           Repl                  (WithCommandAction, withAuxxRepl)

-- 'NodeParams' obtained using 'CLI.getNodeParams' are not perfect for
-- Auxx, so we need to adapt them slightly.
correctNodeParams :: AuxxOptions -> NodeParams -> Production (NodeParams, Bool)
correctNodeParams AuxxOptions {..} np = do
    (dbPath, isTempDbUsed) <- case npDbPathM np of
        Nothing -> do
            tempDir <- liftIO $ Temp.getCanonicalTemporaryDirectory
            dbPath <- liftIO $ Temp.createTempDirectory tempDir "nodedb"
            logInfo $ sformat ("Temporary db created: "%shown) dbPath
            return (dbPath, True)
        Just dbPath -> do
            logInfo $ sformat ("Supplied db used: "%shown) dbPath
            return (dbPath, False)
    let np' = np
            { npNetworkConfig = networkConfig
            , npRebuildDb = npRebuildDb np || isTempDbUsed
            , npDbPathM = Just dbPath }
    return (np', isTempDbUsed)
  where
    topology = TopologyAuxx aoPeers
    networkConfig =
        NetworkConfig
        { ncDefaultPort = 3000
        , ncSelfName = Nothing
        , ncEnqueuePolicy = topologyEnqueuePolicy topology
        , ncDequeuePolicy = topologyDequeuePolicy topology
        , ncFailurePolicy = topologyFailurePolicy topology
        , ncTopology = topology
        , ncTcpAddr = TCP.Unaddressable
        }

runNodeWithSinglePlugin ::
       (HasConfigurations, HasCompileInfo)
    => NodeResources EmptyMempoolExt AuxxMode
    -> (WorkerSpec AuxxMode, OutSpecs)
    -> (WorkerSpec AuxxMode, OutSpecs)
runNodeWithSinglePlugin nr (plugin, plOuts) =
    runNode nr ([plugin], plOuts)

action :: HasCompileInfo => AuxxOptions -> Either (WithCommandAction AuxxMode) Text -> Production ()
action opts@AuxxOptions {..} command = withConfigurations conf $ do
    CLI.printFlags
    logInfo $ sformat ("System start time is "%shown) $ gdStartTime genesisData
    t <- currentTime
    logInfo $ sformat ("Current time is "%shown) (Timestamp t)
    (nodeParams, tempDbUsed) <-
        correctNodeParams opts =<< CLI.getNodeParams cArgs nArgs
    let
        toRealMode :: AuxxMode a -> RealMode EmptyMempoolExt a
        toRealMode auxxAction = do
            realModeContext <- ask
            let auxxContext =
                    AuxxContext
                    { acRealModeContext = realModeContext
                    , acCmdCtx = cmdCtx
                    , acTempDbUsed = tempDbUsed }
            lift $ runReaderT auxxAction auxxContext
    let vssSK = unsafeFromJust $ npUserSecret nodeParams ^. usVss
    let gtParams = CLI.gtSscParams cArgs vssSK (npBehaviorConfig nodeParams)
    bracketNodeResources nodeParams gtParams txpGlobalSettings initNodeDBs $ \nr ->
        runRealBasedMode toRealMode realModeToAuxx nr $
            (if aoNodeEnabled then runNodeWithSinglePlugin nr else identity)
            (auxxPlugin opts command)
  where
    cArgs@CLI.CommonNodeArgs {..} = aoCommonNodeArgs
    conf = CLI.configurationOptions (CLI.commonArgs cArgs)
    nArgs =
        CLI.NodeArgs {sscAlgo = GodTossingAlgo, behaviorConfigPath = Nothing}
    cmdCtx = CmdCtx {ccPeers = aoPeers}

main :: IO ()
main = withCompileInfo $(retrieveCompileTimeInfo) $ do
    opts <- getAuxxOptions
    let disableConsoleLog
            | Repl <- aoAction opts =
                  -- Logging in the REPL disrupts the prompt,
                  -- so we disable it.
                  -- TODO: When LW-25 is resolved we also want
                  -- to be able to enable logging in REPL using
                  -- a Haskeline-compatible print action.
                  \lp -> lp { lpConsoleLog = Just False }
            | otherwise = identity
        loggingParams = disableConsoleLog $
            CLI.loggingParams "auxx" (aoCommonNodeArgs opts)
    loggerBracket loggingParams $ do
        let runAction a = runProduction $ action opts a
        case aoAction opts of
            Repl    -> withAuxxRepl $ \c -> runAction (Left c)
            Cmd cmd -> runAction (Right cmd)
