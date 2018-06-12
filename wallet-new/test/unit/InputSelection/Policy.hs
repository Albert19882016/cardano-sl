{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell            #-}

module InputSelection.Policy (
    InputSelectionPolicy
    -- * Failures
  , InputSelectionHardError(..)
  , InputSelectionSoftError(..)
  , InputSelectionError
    -- * Monad constriants
  , LiftQuickCheck(..)
  , RunPolicy(..)
    -- * UTxO constraints
  , IsUtxo(..)
  , fromUtxo
  , convertUtxo
    -- * Transaction statistics
  , TxStats(..)
    -- * Convenience re-exports
  , DSL.GivenHash(..)
  , DSL.Hash(..)
  , DSL.Input(..)
  , DSL.Output(..)
  , DSL.Transaction(..)
  , DSL.Value
  ) where

import           Universum

import           Data.Fixed (E2, Fixed)
import           Test.QuickCheck hiding (Fixed)

import           Util.Histogram (Histogram)
import qualified Util.Histogram as Histogram
import           Util.MultiSet (MultiSet)
import qualified Util.MultiSet as MultiSet
import           Util.StrictStateT
import           UTxO.DSL (Hash, Output, Transaction, Utxo, Value)
import qualified UTxO.DSL as DSL

{-------------------------------------------------------------------------------
  Constraints on the monad in which we run the input selection policy
-------------------------------------------------------------------------------}

-- | Monads in which we can run QuickCheck generators
class Monad m => LiftQuickCheck m where
   -- | Run a QuickCheck computation
  liftQuickCheck :: Gen x -> m x

-- | Monads in which we can run input selection policies
class Monad m => RunPolicy m a | m -> a where
  -- | Generate change address
  genChangeAddr :: m a

  -- | Generate fresh hash
  genFreshHash :: m Int

-- | TODO: We probably don't want this instance (or abstract in a different
-- way over "can generate random numbers")
instance LiftQuickCheck IO where
  liftQuickCheck = generate

instance LiftQuickCheck m => LiftQuickCheck (StrictStateT s m) where
  liftQuickCheck = lift . liftQuickCheck

{-------------------------------------------------------------------------------
  Generalization over different UTxO representations
-------------------------------------------------------------------------------}

-- | Abstract from UTxO representation
--
-- Different policies need to maintain the UTxO in different forms, to support
-- their operation efficiently. For example, the largest first policy may want
-- to store the UTxO as a sorted list.
class IsUtxo utxo where
  -- | Construct empty
  utxoEmpty :: utxo h a

  -- | Add in entries from a "normal" UTxO
  utxoUnion :: Hash h a => Utxo h a -> utxo h a -> utxo h a

  -- | Number of entries in the UTxO
  utxoSize :: utxo h a -> Int

  -- | Total balance
  utxoBalance :: utxo h a -> Value

  -- | List of all output values
  --
  -- The length of this list should be equal to 'utxoSize'
  utxoOutputs :: Hash h a => utxo h a -> [Value]

  -- | Remove inputs from the domain
  --
  -- We take the inputs as a UTxO so that we know what their balance is.
  utxoRemoveInputs :: Hash h a => Utxo h a -> utxo h a -> utxo h a

  -- | Convert to regular utxo
  toUtxo :: Hash h a => utxo h a -> Utxo h a

-- | Convert "normal" UTxO into this policy-specific representation
fromUtxo :: (IsUtxo utxo, Hash h a) => Utxo h a -> utxo h a
fromUtxo = flip utxoUnion utxoEmpty

-- | Convert one UTxO representation to antoher
convertUtxo :: (IsUtxo utxo, IsUtxo utxo', Hash h a) => utxo h a -> utxo' h a
convertUtxo = fromUtxo . toUtxo

instance IsUtxo Utxo where
  utxoEmpty        = DSL.utxoEmpty
  utxoUnion        = DSL.utxoUnion
  utxoSize         = DSL.utxoSize
  utxoBalance      = DSL.utxoBalance
  utxoRemoveInputs = DSL.utxoRemoveInputs . DSL.utxoDomain
  utxoOutputs      = map (DSL.outVal . snd) . DSL.utxoToList
  toUtxo           = identity

{-------------------------------------------------------------------------------
  Transaction statistics
-------------------------------------------------------------------------------}

-- | Transaction statistics
--
-- Transaction statistics are used for policy evaluation. For "real" input
-- selection policies we don't necessarily need to return this information,
-- although it may be beneficial to do so even there -- it may be useful
-- to monitor these statistics and learn something about the wallet as it
-- operates in reality.
data TxStats = TxStats {
      -- | Number of inputs
      --
      -- This is a histogram because although a single transaction only has
      -- a single value for its number of inputs, recording this as a histogram
      -- allows us to combine the statistics of many transactions.
      txStatsNumInputs :: !Histogram

      -- | Change/payment ratios
    , txStatsRatios    :: !(MultiSet (Fixed E2))
    }

instance Monoid TxStats where
  mempty = TxStats {
        txStatsNumInputs = Histogram.empty
      , txStatsRatios    = MultiSet.empty
      }
  mappend a b = TxStats {
        txStatsNumInputs = mappendUsing Histogram.add  txStatsNumInputs
      , txStatsRatios    = mappendUsing MultiSet.union txStatsRatios
      }
    where
      mappendUsing :: (a -> a -> a) -> (TxStats -> a) -> a
      mappendUsing op f = f a `op` f b

{-------------------------------------------------------------------------------
  Policy
-------------------------------------------------------------------------------}

-- | Input selection policy
--
-- An input selection policy is a function that given a UTxO and a bunch
-- of outputs constructs a transaction with at least those outputs.
--
-- In addition to the generated transaction, we also return the UTxO that
-- we used (which must be a subset of the UTxO that was passed in), as well
-- as some statistics about this transaction.
type InputSelectionPolicy utxo h a m =
      utxo h a
   -> [Output a]
   -> m (Either InputSelectionHardError (Transaction h a, TxStats, Utxo h a))

{-------------------------------------------------------------------------------
  Failures
-------------------------------------------------------------------------------}

-- | This input selection request is unsatisfiable
--
-- These are errors we cannot recover from.
data InputSelectionHardError = InputSelectionHardError

-- | The input selection request failed
--
-- The algorithm failed to find a solution, but that doesn't necessarily mean
-- that there isn't one.
data InputSelectionSoftError = InputSelectionSoftError

-- | Union of the two kinds of input selection failures
type InputSelectionError = Either InputSelectionHardError InputSelectionSoftError
