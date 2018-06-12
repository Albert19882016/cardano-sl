{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell            #-}
-- | Monad that can be used to implement input selection policies
module InputSelection.Policy.InputPolicyT (
    InputPolicyT -- opaque
  , runInputPolicyT
  , catchSoftError
  , mapInputPolicyErrors
    -- * State
  , ipsUtxo
  , ipsSelectedInputs
  , ipsGeneratedOutputs
    -- * Partial transaction statistics
  , PartialTxStats(..)
  ) where

import           Universum

import           Control.Lens.TH (makeLenses)
import           Control.Monad.Except (MonadError (..))
import           Data.Fixed (E2, Fixed)

import           InputSelection.Policy
import           Util.Histogram (BinSize (..))
import qualified Util.Histogram as Histogram
import           Util.MultiSet (MultiSet)
import qualified Util.MultiSet as MultiSet
import           Util.StrictStateT
import qualified UTxO.DSL as DSL

{-------------------------------------------------------------------------------
  Internal state
-------------------------------------------------------------------------------}

data InputPolicyState utxo h a = InputPolicyState {
      -- | Available entries in the UTxO
      _ipsUtxo             :: !(utxo h a)

      -- | Selected inputs
    , _ipsSelectedInputs   :: !(DSL.Utxo h a)

      -- | Generated outputs
    , _ipsGeneratedOutputs :: [Output a]
    }

initInputPolicyState :: utxo h a -> InputPolicyState utxo h a
initInputPolicyState utxo = InputPolicyState {
      _ipsUtxo             = utxo
    , _ipsSelectedInputs   = DSL.utxoEmpty
    , _ipsGeneratedOutputs = []
    }

makeLenses ''InputPolicyState

{-------------------------------------------------------------------------------
  Partial transaction statistics
-------------------------------------------------------------------------------}

-- | Partial transaciton statistics
--
-- Partial transactions statistics are useful when constructing a transaciton
-- piece by piece.
data PartialTxStats = PartialTxStats {
      -- | Number of inputs
      --
      -- Unlike for 'TxStats', this is not a histogram. Suppose we have two
      -- 'PartialTxStats' with 'ptxStatsNumInputs' equal to @n@ and @m@.
      -- Then the final histogram should have a single bin at @n + m@ with
      -- count 1. This is rather different from having two transactions with
      -- @n@ inputs and @m@ outputs; this would result in a histogram with
      -- /two/ bins at @n@ and @m@ both with count 1, or, if @n == m@, a
      -- single bin at @n@ with count 2.
      ptxStatsNumInputs :: !Int

      -- | Change/payment ratios
    , ptxStatsRatios    :: !(MultiSet (Fixed E2))
    }

instance Monoid PartialTxStats where
  mempty = PartialTxStats {
        ptxStatsNumInputs = 0
      , ptxStatsRatios    = MultiSet.empty
      }
  mappend a b = PartialTxStats {
        ptxStatsNumInputs = mappendUsing (+)            ptxStatsNumInputs
      , ptxStatsRatios    = mappendUsing MultiSet.union ptxStatsRatios
      }
    where
      mappendUsing :: (a -> a -> a) -> (PartialTxStats -> a) -> a
      mappendUsing op f = f a `op` f b

-- | Construct transaciton statistics from partial statistics
fromPartialTxStats :: PartialTxStats -> TxStats
fromPartialTxStats PartialTxStats{..} = TxStats{
      txStatsNumInputs = Histogram.singleton (BinSize 1) ptxStatsNumInputs 1
    , txStatsRatios    = ptxStatsRatios
    }

{-------------------------------------------------------------------------------
  The monad itself
-------------------------------------------------------------------------------}

-- | Monad that can be uesd to define input selection policies
newtype InputPolicyT utxo e h a m x = InputPolicyT {
      unInputPolicyT :: StrictStateT
                          (InputPolicyState utxo h a)
                          (ExceptT e m)
                          x
    }
  deriving ( Functor
           , Applicative
           , Monad
           , MonadState (InputPolicyState utxo h a)
           , MonadError e
           )

-- | Unwrap the 'InputPolicyT' stack
--
-- NOTE: This stack is carefully defined so that if an error occurs, we do
-- /not/ get a final state value. This means that when we catch errors and
-- provide error handlers, those error handlers will run with the state as it
-- was /before/ the action they wrapped.
unwrapInputPolicyT :: InputPolicyT utxo e h a m x
                   -> InputPolicyState utxo h a
                   -> m (Either e (x, InputPolicyState utxo h a))
unwrapInputPolicyT act st = runExceptT (runStrictStateT (unInputPolicyT act) st)

-- | Inverse of 'unwrapInputPolicyT'
wrapInputPolicyT :: Monad m
                 => (    InputPolicyState utxo h a
                      -> m (Either e (x, InputPolicyState utxo h a)) )
                 -> InputPolicyT utxo e h a m x
wrapInputPolicyT f = InputPolicyT $ strictStateT $ \st -> ExceptT $ f st

-- | Change errors
mapInputPolicyErrors :: Monad m
                     => (e -> e')
                     -> InputPolicyT utxo e  h a m x
                     -> InputPolicyT utxo e' h a m x
mapInputPolicyErrors f act = wrapInputPolicyT $ \st ->
    bimap f identity <$> unwrapInputPolicyT act st

instance MonadTrans (InputPolicyT utxo e h a) where
  lift = InputPolicyT . lift . lift

instance LiftQuickCheck m => LiftQuickCheck (InputPolicyT utxo e h a m) where
  liftQuickCheck = lift . liftQuickCheck

instance RunPolicy m a => RunPolicy (InputPolicyT utxo e h a m) a where
  genChangeAddr = lift genChangeAddr
  genFreshHash  = lift genFreshHash

runInputPolicyT :: RunPolicy m a
                => utxo h a
                -> InputPolicyT utxo e h a m PartialTxStats
                -> m (Either e (Transaction h a, TxStats, DSL.Utxo h a))
runInputPolicyT utxo policy = do
     mx <- unwrapInputPolicyT policy initSt
     case mx of
       Left err ->
         return $ Left err
       Right (ptxStats, finalSt) -> do
         h <- genFreshHash
         return $ Right (
             Transaction {
                 trFresh = 0
               , trIns   = DSL.utxoDomain (finalSt ^. ipsSelectedInputs)
               , trOuts  = finalSt ^. ipsGeneratedOutputs
               , trFee   = 0 -- TODO: deal with fees
               , trHash  = h
               , trExtra = []
               }
           , fromPartialTxStats ptxStats
           , finalSt ^. ipsSelectedInputs
           )
  where
    initSt = initInputPolicyState utxo

-- | Catch only recoverable errors
catchSoftError :: Monad m
               => InputPolicyT utxo InputSelectionError h a m x
               -> (InputSelectionSoftError ->
                     InputPolicyT utxo InputSelectionHardError h a m x)
               -> InputPolicyT utxo InputSelectionHardError h a m x
catchSoftError act handler = wrapInputPolicyT $ \st -> do
    ma <- unwrapInputPolicyT act st
    case ma of
      Left (Right err) -> unwrapInputPolicyT (handler err) st
      Left (Left err)  -> return $ Left err
      Right a          -> return $ Right a
