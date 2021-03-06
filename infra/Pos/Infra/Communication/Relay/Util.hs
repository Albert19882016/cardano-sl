module Pos.Infra.Communication.Relay.Util
       ( expectInv
       , expectData
       ) where

import           Universum

import           Pos.Infra.Communication.Relay.Types (RelayError (UnexpectedData, UnexpectedInv))
import           Pos.Infra.Communication.Types.Relay (DataMsg, InvMsg,
                                                      InvOrData)

expectInv
    :: MonadThrow m
    => (InvMsg key -> m a) -> InvOrData key contents -> m a
expectInv call = either call (\_ -> throwM UnexpectedData)

expectData
    :: MonadThrow m
    => (DataMsg contents -> m a) -> InvOrData key contents -> m a
expectData call = either (\_ -> throwM UnexpectedInv) call
