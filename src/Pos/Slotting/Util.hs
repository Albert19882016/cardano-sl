{-# LANGUAGE ConstraintKinds #-}

-- | Slotting utilities.

module Pos.Slotting.Util
       (
         -- * Helpers using 'MonadSlots'
         getCurrentSlotFlat
       , getSlotStart

         -- * Worker which ticks when slot starts
       , onNewSlot
       , onNewSlotImpl

         -- * Worker which logs beginning of new slot
       , logNewSlotWorker

         -- * Waiting for system start
       , waitSystemStart
       ) where

import           Control.Monad.Catch      (MonadCatch, catch)
import           Formatting               (build, int, sformat, (%))
import           Mockable                 (Delay, Fork, Mockable, delay, fork)
import           Serokell.Util.Exceptions ()
import           System.Wlog              (WithLogger, logDebug, logError, logInfo,
                                           logNotice, modifyLoggerName)
import           Universum

import           Pos.Constants            (ntpMaxError, ntpPollDelay)
import           Pos.Context              (WithNodeContext (getNodeContext),
                                           ncSystemStart)
import           Pos.Slotting.Class       (MonadSlots (..))
import           Pos.Types                (FlatSlotId, SlotId (..), Timestamp (..),
                                           flattenSlotId, slotIdF, unflattenSlotId)
import           Pos.Util.Shutdown        (ifNotShutdown)
import           Pos.Util.TimeWarp        (sec)

-- | Get flat id of current slot based on MonadSlots.
getCurrentSlotFlat :: MonadSlots m => m (Maybe FlatSlotId)
getCurrentSlotFlat = fmap flattenSlotId <$> getCurrentSlot

-- | Get timestamp when given slot starts.
getSlotStart :: MonadSlots m => SlotId -> m Timestamp
getSlotStart = notImplemented
-- getSlotStart (flattenSlotId -> slotId) = do
--     slotDuration <- getSlotDuration
--     startTime    <- getSystemStartTime
--     return $ startTime +
--              Timestamp (fromIntegral slotId * convertUnit slotDuration)

-- | Type constraint for `onNewSlot*` workers
type OnNewSlot ssc m =
    ( MonadIO m
    , MonadSlots m
    , MonadCatch m
    , WithLogger m
    , Mockable Fork m
    , Mockable Delay m
    , WithNodeContext ssc m
    )

-- | Run given action as soon as new slot starts, passing SlotId to
-- it.  This function uses Mockable and assumes consistency between
-- MonadSlots and Mockable implementations.
onNewSlot
    :: OnNewSlot ssc m
    => Bool -> (SlotId -> m ()) -> m ()
onNewSlot = onNewSlotImpl False

onNewSlotWithLogging
    :: OnNewSlot ssc m
    => Bool -> (SlotId -> m ()) -> m ()
onNewSlotWithLogging = onNewSlotImpl True

onNewSlotImpl
    :: OnNewSlot ssc m
    => Bool -> Bool -> (SlotId -> m ()) -> m ()
onNewSlotImpl withLogging startImmediately action =
    onNewSlotDo withLogging Nothing startImmediately actionWithCatch
  where
    -- TODO [CSL-198]: think about exceptions more carefully.
    actionWithCatch s = action s `catch` handler
    handler :: WithLogger m => SomeException -> m ()
    handler = logError . sformat ("Error occurred: "%build)

onNewSlotDo
    :: OnNewSlot ssc m
    => Bool -> Maybe SlotId -> Bool -> (SlotId -> m ()) -> m ()
onNewSlotDo withLogging expectedSlotId startImmediately action = ifNotShutdown $ notImplemented
-- onNewSlotDo withLogging expectedSlotId startImmediately action = ifNotShutdown $ do
--     -- here we wait for short intervals to be sure that expected slot
--     -- has really started, taking into account possible inaccuracies
--     waitUntilPredicate
--         (maybe (const True) (<=) expectedSlotId <$> getCurrentSlot)
--     curSlot <- getCurrentSlot
--     -- fork is necessary because action can take more time than slotDuration
--     when startImmediately $ void $ fork $ action curSlot

--     -- check for shutdown flag again to not wait a whole slot
--     ifNotShutdown $ do
--         Timestamp curTime <- undefined -- getCurrentTime
--         let nextSlot = succ curSlot
--         Timestamp nextSlotStart <- getSlotStart nextSlot
--         let timeToWait = nextSlotStart - curTime
--         when (timeToWait > 0) $ do
--             when withLogging $ logTTW timeToWait
--             delay timeToWait
--         onNewSlotDo withLogging (Just nextSlot) True action
--   where
--     waitUntilPredicate predicate =
--         unlessM predicate (shortWait >> waitUntilPredicate predicate)
--     shortWait = do
--         -- slotDuration <- getSlotDuration
--         -- delay ((10 :: Microsecond) `max` (convertUnit slotDuration `div` 10000))
--         delay (10 :: Microsecond)
--     logTTW timeToWait = modifyLoggerName (<> "slotting") $ logDebug $
--                  sformat ("Waiting for "%shown%" before new slot") timeToWait

logNewSlotWorker
    :: OnNewSlot ssc m
    => m ()
logNewSlotWorker =
    onNewSlotWithLogging True $ \slotId -> do
        modifyLoggerName (<> "slotting") $
            logNotice $ sformat ("New slot has just started: " %slotIdF) slotId

-- getSlotDuration = pure genesisSlotDuration

-- | Wait until system starts. This function is useful if node is
-- launched before 0-th epoch starts.
waitSystemStart
    :: (WithNodeContext ssc m, Mockable Delay m, WithLogger m, MonadSlots m)
    => m ()
waitSystemStart = do
    start <- ncSystemStart <$> getNodeContext
    cur <- currentTimeSlotting
    let Timestamp waitPeriod = start - cur
    when (cur < start) $ do
        logInfo $ sformat ("Waiting "%int%" seconds for system start") $
            waitPeriod `div` sec 1
        delay waitPeriod
