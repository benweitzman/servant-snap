{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE KindSignatures #-}

module Servant.API.ReqQueryParam where

import Data.Typeable (Typeable)
import GHC.TypeLits (Symbol)

data ReqQueryParam (sym :: Symbol) a
  deriving Typeable
