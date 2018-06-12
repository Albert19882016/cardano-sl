module Util (
    -- * Lists
    at
  , mergeBy
    -- * Maps and sets
  , disjoint
  , withoutKeys
  , restrictKeys
    -- * Dealing with OldestFirst/NewestFirst
  , liftOldestFirst
  , liftNewestFirst
    -- * Probabilities
  , Probability
  , toss
  ) where

import           Universum

import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import           Pos.Util.Chrono
import qualified Test.QuickCheck as QC

{-------------------------------------------------------------------------------
  Lists
-------------------------------------------------------------------------------}

-- | Safe version of (!!)
at :: [a] -> Int -> Maybe a
at []     _ = Nothing
at (x:_)  0 = Just x
at (_:xs) i = at xs (i - 1)

-- | Merge two sorted lists
mergeBy :: (a -> a -> Ordering) -> [a] -> [a] -> [a]
mergeBy _  [] ys  = ys
mergeBy _ xs []   = xs
mergeBy f (x:xs) (y:ys)
    | f x y == LT = x : mergeBy f xs (y:ys)
    | otherwise   = y : mergeBy f (x:xs) ys

{-------------------------------------------------------------------------------
  Maps and sets
-------------------------------------------------------------------------------}

-- | Check that two sets are disjoint
--
-- This is available out of the box from @containters >= 0.5.11@
disjoint :: Ord a => Set a -> Set a -> Bool
disjoint a b = Set.null (a `Set.intersection` b)

withoutKeys :: Ord k => Map k a -> Set k -> Map k a
m `withoutKeys` s = m `Map.difference` Map.fromSet (const ()) s

restrictKeys :: Ord k => Map k a -> Set k -> Map k a
m `restrictKeys` s = m `Map.intersection` Map.fromSet (const ()) s

{-------------------------------------------------------------------------------
  Dealing with OldestFirst/NewestFirst
-------------------------------------------------------------------------------}

liftOldestFirst :: (f a -> f a) -> OldestFirst f a -> OldestFirst f a
liftOldestFirst f = OldestFirst . f . getOldestFirst

liftNewestFirst :: (f a -> f a) -> NewestFirst f a -> NewestFirst f a
liftNewestFirst f = NewestFirst . f . getNewestFirst

{-------------------------------------------------------------------------------
  Probabilities
-------------------------------------------------------------------------------}

-- | Probability (value between 0 and 1)
type Probability = Double

-- | Weighted coin toss
--
-- @toss p@ throws a p-weighted coin and returns whether it came up heads.
-- @toss 0@ will always return @False@, @toss 1@ will always return @True@.
toss :: Probability -> QC.Gen Bool
toss 0 = return False
toss 1 = return True
toss p = (< p) <$> QC.choose (0, 1)
