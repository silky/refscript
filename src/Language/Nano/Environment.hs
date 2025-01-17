
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE TypeSynonymInstances      #-}
{-# LANGUAGE DeriveFunctor             #-}
{-# LANGUAGE UndecidableInstances      #-}

module Language.Nano.Environment where

import           Data.Maybe           (isJust)
import           Language.Nano.Types
import           Language.Nano.Env
import           Language.Nano.Names
import           Language.Nano.Program
import           Language.Fixpoint.Types.Names
import           Language.Nano.Syntax.PrettyPrint
import qualified Language.Fixpoint.Types            as F

-------------------------------------------------------------------------------
-- | Typecheck Environment
-------------------------------------------------------------------------------

class EnvLike r t where
  -- 
  -- ^ Bindings in scope
  --   Includes : variables, functions, classes, interfaces
  --
  names           :: t r -> Env (EnvEntry r)
  -- 
  -- ^ Modules in scope (exported API)
  --
  modules         :: t r -> QEnv (ModuleDef r)
  -- 
  -- ^ ClassHierarchy
  -- 
  cha             :: t r -> ClassHierarchy r
  -- 
  -- ^ Namespace absolute path
  --
  absPath         :: t r -> AbsPath
  -- 
  -- ^ Calling context
  --
  context         :: t r -> IContext
  -- 
  -- ^ Parent environment
  --
  parent          :: t r -> Maybe (t r)


data EnvEntry r = EE { 
    ee_asgn :: Assignability 
  , ee_init :: Initialization
  , ee_type :: RType r
  } deriving (Functor)


instance (F.Reftable r, PP r) => PP (EnvEntry r) where  
  pp (EE _ _ t) = pp t

-------------------------------------------------------------------------------
envLikeFindTy' :: (EnvLike r t, Symbolic a) => a -> t r -> Maybe (EnvEntry r)
-------------------------------------------------------------------------------
envLikeFindTy' x γ | Just t  <- envFindTy x $ names γ = Just t
                   | Just γ' <- parent γ              = envLikeFindTy' x γ'
                   | otherwise                        = Nothing

-------------------------------------------------------------------------------
envLikeFindTy :: (EnvLike r t, Symbolic a) => a -> t r -> Maybe (RType r)
-------------------------------------------------------------------------------
envLikeFindTy x = fmap ee_type . envLikeFindTy' x

envLikeMember x = isJust . envLikeFindTy x

