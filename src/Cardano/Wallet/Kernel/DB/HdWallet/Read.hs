{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RankNTypes                 #-}

-- | READ queries on the HD wallet
--
-- NOTE: These are pure functions, which are intended to work on a snapshot
-- of the database. They are intended to support the V1 wallet API.
module Cardano.Wallet.Kernel.DB.HdWallet.Read (
    -- | Summarize
    accountsByRootId
  , addressesByRootId
  , addressesByAccountId
    -- | Simple lookups
  , lookupHdRootId
  , lookupHdAccountId
  , lookupHdAddressId
  , lookupCardanoAddress
    -- | Properties of an entire root
  , rootAssuranceLevel
  , rootTotalBalance
    -- | Queries on an account's current checkpoint
  , currentUtxo
  , currentAvailableUtxo
  , currentTotalBalance
  , currentAvailableBalance
  , currentAddressMeta
  , currentTxSlotId
  , currentTxIsPending
  ) where

import           Universum

import           Pos.Chain.Txp (TxId, Utxo)
import           Pos.Core (Address, Coin, SlotId, mkCoin, unsafeAddCoin)

import           Cardano.Wallet.Kernel.DB.BlockMeta (AddressMeta)
import           Cardano.Wallet.Kernel.DB.HdWallet
import           Cardano.Wallet.Kernel.DB.InDb
import           Cardano.Wallet.Kernel.DB.Spec (IsCheckpoint (..),
                     cpAddressMeta)
import           Cardano.Wallet.Kernel.DB.Spec.Read
import           Cardano.Wallet.Kernel.DB.Util.AcidState
import           Cardano.Wallet.Kernel.DB.Util.IxSet (Indexed, IxSet)
import qualified Cardano.Wallet.Kernel.DB.Util.IxSet as IxSet

{-------------------------------------------------------------------------------
  Summarize
-------------------------------------------------------------------------------}

-- | All accounts in the given wallet
--
-- NOTE: Does not check that the root exists.
accountsByRootId :: HdRootId -> Query' HdWallets e (IxSet HdAccount)
accountsByRootId rootId = do
    asks $ IxSet.getEQ rootId . view hdWalletsAccounts

-- | All addresses in the given wallet
--
-- NOTE: Does not check that the root exists.
addressesByRootId :: HdRootId -> Query' HdWallets e (IxSet (Indexed HdAddress))
addressesByRootId rootId =
    asks $ IxSet.getEQ rootId . view hdWalletsAddresses

-- | All addresses in the given account
--
-- NOTE: Does not check that the account exists.
addressesByAccountId :: HdAccountId -> Query' HdWallets e (IxSet (Indexed HdAddress))
addressesByAccountId accId =
    asks $ IxSet.getEQ accId . view hdWalletsAddresses

{-------------------------------------------------------------------------------
  Simple lookups
-------------------------------------------------------------------------------}

lookupHdRootId :: HdRootId -> Query' HdWallets UnknownHdRoot HdRoot
lookupHdRootId rootId = zoomHdRootId identity rootId $ ask

lookupHdAccountId :: HdAccountId -> Query' HdWallets UnknownHdAccount HdAccount
lookupHdAccountId accId = zoomHdAccountId identity accId $ ask

lookupHdAddressId :: HdAddressId -> Query' HdWallets UnknownHdAddress HdAddress
lookupHdAddressId addrId = zoomHdAddressId identity addrId $ ask

lookupCardanoAddress :: Address -> Query' HdWallets UnknownHdAddress HdAddress
lookupCardanoAddress addr = zoomHdCardanoAddress identity addr $ ask

{-------------------------------------------------------------------------------
  Properties of an entire HdRoot
-------------------------------------------------------------------------------}

rootAssuranceLevel :: HdRootId -> Query' HdWallets UnknownHdRoot AssuranceLevel
rootAssuranceLevel rootId =
    zoomHdRootId identity rootId $
      view hdRootAssurance

-- | Total balance for all accounts in the given root
--
-- NOTE: Does not check that the root exists.
rootTotalBalance :: HdRootId -> Query' HdWallets e Coin
rootTotalBalance rootId = do
    accounts <- IxSet.getEQ rootId <$> view hdWalletsAccounts
    sumTotals <$> mapM currentTotalBalance' (IxSet.toList accounts)
  where
    sumTotals :: [Coin] -> Coin
    sumTotals = foldl' unsafeAddCoin (mkCoin 0)

{-------------------------------------------------------------------------------
  Functions on the most recent checkpoint
-------------------------------------------------------------------------------}

-- | Internal: lift a function on the current checkpoint
liftCP :: (forall c. IsCheckpoint c => c -> a)
       -> HdAccountId -> Query' HdWallets UnknownHdAccount a
liftCP f accId =
    zoomHdAccountId identity accId $
      zoomHdAccountCurrent $
        asks f

currentUtxo :: HdAccountId -> Query' HdWallets UnknownHdAccount Utxo
currentUtxo = liftCP (view cpUtxo)

currentAvailableUtxo :: HdAccountId -> Query' HdWallets UnknownHdAccount Utxo
currentAvailableUtxo = liftCP cpAvailableUtxo

currentTxSlotId :: TxId -> HdAccountId -> Query' HdWallets UnknownHdAccount (Maybe SlotId)
currentTxSlotId txId = liftCP $ cpTxSlotId txId

currentTxIsPending :: TxId -> HdAccountId -> Query' HdWallets UnknownHdAccount Bool
currentTxIsPending txId = liftCP $ cpTxIsPending txId

currentAvailableBalance :: HdAccountId -> Query' HdWallets UnknownHdAccount Coin
currentAvailableBalance = liftCP cpAvailableBalance

currentAddressMeta :: HdAddress -> Query' HdWallets UnknownHdAccount AddressMeta
currentAddressMeta = withAddr $ \addr ->
    liftCP $ view (cpAddressMeta (addr ^. hdAddressAddress . fromDb))
  where
    withAddr :: (HdAddress -> HdAccountId -> Query' st e a)
             -> (HdAddress -> Query' st e a)
    withAddr f addr = f addr (addr ^. hdAddressId . hdAddressIdParent)

currentTotalBalance :: HdAccountId -> Query' HdWallets UnknownHdAccount Coin
currentTotalBalance accId =
    zoomHdAccountId identity accId ask >>= currentTotalBalance'

-- Internal helper generalization
--
-- Total balance breaks the pattern because we need the set of addresses that
-- belong to the account, but for that we need 'HdWallets'.
currentTotalBalance' :: HdAccount -> Query' HdWallets e Coin
currentTotalBalance' acc = do
    ourAddrs <- IxSet.getEQ (acc ^. hdAccountId) <$> view hdWalletsAddresses
    return $ cpTotalBalance ourAddrs cp
  where
    cp = acc ^. hdAccountState . hdAccountStateCurrent