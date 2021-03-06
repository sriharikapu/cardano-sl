{-# LANGUAGE TypeFamilies #-}

-- | Various small endpoints

module Pos.Wallet.Web.Methods.Misc
       ( getUserProfile
       , updateUserProfile

       , isValidAddress

       , nextUpdate
       , postponeUpdate
       , applyUpdate

       , syncProgress
       , localTimeDifference

       , testResetAll
       ) where

import           Universum

import           Pos.Client.KeyStorage      (MonadKeys, deleteSecretKey, getSecretKeys)
import           Pos.Core                   (SoftwareVersion (..), decodeTextAddress)
import           Pos.NtpCheck               (NtpStatus (..), mkNtpStatusVar)
import           Pos.Update.Configuration   (curSoftwareVersion)
import           Pos.Util                   (maybeThrow)

import           Pos.Wallet.WalletMode      (applyLastUpdate, connectedPeers,
                                             localChainDifficulty, networkChainDifficulty)
import           Pos.Wallet.Web.ClientTypes (CProfile (..), CUpdateInfo (..),
                                             SyncProgress (..))
import           Pos.Wallet.Web.Error       (WalletError (..))
import           Pos.Wallet.Web.Mode        (MonadWalletWebMode)
import           Pos.Wallet.Web.State       (getNextUpdate, getProfile, removeNextUpdate,
                                             setProfile, testReset)


----------------------------------------------------------------------------
-- Profile
----------------------------------------------------------------------------

getUserProfile :: MonadWalletWebMode ctx m => m CProfile
getUserProfile = getProfile

updateUserProfile :: MonadWalletWebMode ctx m => CProfile -> m CProfile
updateUserProfile profile = setProfile profile >> getUserProfile

----------------------------------------------------------------------------
-- Address
----------------------------------------------------------------------------

-- NOTE: later we will have `isValidAddress :: CId -> m Bool` which should work for arbitrary crypto
isValidAddress :: MonadWalletWebMode ctx m => Text -> m Bool
isValidAddress sAddr =
    pure . isRight $ decodeTextAddress sAddr

----------------------------------------------------------------------------
-- Updates
----------------------------------------------------------------------------

-- | Get last update info
nextUpdate :: MonadWalletWebMode ctx m => m CUpdateInfo
nextUpdate = do
    updateInfo <- getNextUpdate >>= maybeThrow noUpdates
    if isUpdateActual (cuiSoftwareVersion updateInfo)
        then pure updateInfo
        else removeNextUpdate >> nextUpdate
  where
    isUpdateActual :: SoftwareVersion -> Bool
    isUpdateActual ver = svAppName ver == svAppName curSoftwareVersion
        && svNumber ver > svNumber curSoftwareVersion
    noUpdates = RequestError "No updates available"

-- | Postpone next update after restart
postponeUpdate :: MonadWalletWebMode ctx m => m ()
postponeUpdate = removeNextUpdate

-- | Delete next update info and restart immediately
applyUpdate :: MonadWalletWebMode ctx m => m ()
applyUpdate = removeNextUpdate >> applyLastUpdate

----------------------------------------------------------------------------
-- Sync progress
----------------------------------------------------------------------------

syncProgress :: MonadWalletWebMode ctx m => m SyncProgress
syncProgress =
    SyncProgress
    <$> localChainDifficulty
    <*> networkChainDifficulty
    <*> connectedPeers

----------------------------------------------------------------------------
-- NTP (Network Time Protocol) based time difference
----------------------------------------------------------------------------

localTimeDifference :: MonadWalletWebMode ctx m => m Word
localTimeDifference =
    mkNtpStatusVar >>= readMVar >>= pure . diff
  where
    diff :: NtpStatus -> Word
    diff = \case
        NtpSyncOk -> 0
        -- ^ `NtpSyncOk` considered already a `timeDifferenceWarnThreshold`
        -- so that we can return 0 here to show there is no difference in time
        NtpDesync diff' -> fromIntegral diff'

----------------------------------------------------------------------------
-- Reset
----------------------------------------------------------------------------

testResetAll :: MonadWalletWebMode ctx m => m ()
testResetAll = deleteAllKeys >> testReset
  where
    deleteAllKeys :: MonadKeys m => m ()
    deleteAllKeys = do
        keyNum <- length <$> getSecretKeys
        replicateM_ keyNum $ deleteSecretKey 0
