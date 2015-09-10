{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE DoAndIfThenElse           #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE ImpredicativeTypes        #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE LiberalTypeSynonyms       #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE TupleSections             #-}

-- | This module has the code for the Type-Checker Monad.

module Language.Rsc.Typecheck.TCMonad (
  -- * TC Monad
    TCM

  -- * Execute
  , execute
  , runFailM, runMaybeM

  -- * Errors
  , logError, tcError, tcWrap

  -- * Freshness
  , freshTyArgs, freshenAnn

  -- * Substitutions
  , getSubst, setSubst, addSubst

  -- * Function Types
  , tcFunTys

  -- * Annotations
  , addAnn {-TEMP-}, getAnns

  -- * Unification
  , unifyTypeM, unifyTypesM

  -- * Subtyping
  , subtypeM, isSubtype, checkTypes

  -- * Casts
  , castM, deadcastM, freshCastId, isCastId

  -- * Verbosity / Options
  , whenLoud', whenLoud, whenQuiet', whenQuiet, getOpts, getAstCount

  )  where


import           Control.Applicative                ((<$>), (<*>))
import           Control.Monad.Except               (catchError)
import           Control.Monad.State
import           Control.Monad.Trans.Except
import           Data.Either                        (partitionEithers)
import           Data.Function                      (on)
import qualified Data.HashMap.Strict                as M
import qualified Data.IntMap.Strict                 as I
import           Data.List                          (isPrefixOf)
import           Data.Maybe                         (catMaybes)
import           Data.Monoid
import           Language.Fixpoint.Errors
import           Language.Fixpoint.Misc
import qualified Language.Fixpoint.Types            as F
import           Language.Rsc.Annots
import           Language.Rsc.AST
import           Language.Rsc.ClassHierarchy
import           Language.Rsc.CmdLine
import           Language.Rsc.Core.Env
import           Language.Rsc.Errors
import           Language.Rsc.Locations
import           Language.Rsc.Misc
import           Language.Rsc.Names
import           Language.Rsc.Pretty
import           Language.Rsc.Program
import           Language.Rsc.Typecheck.Environment
import           Language.Rsc.Typecheck.Sub
import           Language.Rsc.Typecheck.Subst
import           Language.Rsc.Typecheck.Types
import           Language.Rsc.Typecheck.Unify
import           Language.Rsc.Types
import qualified System.Console.CmdArgs.Verbosity   as V


-------------------------------------------------------------------------------
-- | Typechecking monad
-------------------------------------------------------------------------------

data TCState r = TCS {
  --
  -- ^ Errors
  --
    tc_errors  :: ![Error]
  --
  -- ^ Substitutions
  --
  , tc_subst   :: !(RSubst r)
  --
  -- ^ Freshness counter
  --
  , tc_cnt     :: !Int
  --
  -- ^ Annotations
  --
  , tc_anns    :: AnnInfo r
  --
  -- ^ Verbosity
  --
  , tc_verb    :: V.Verbosity
  --
  -- ^ configuration options
  --
  , tc_opts    :: Config
  --
  -- ^ AST Counter
  --
  , tc_ast_cnt :: NodeId

  }

type TCM r     = ExceptT Error (State (TCState r))

-------------------------------------------------------------------------------
whenLoud :: TCM r () -> TCM r ()
-------------------------------------------------------------------------------
whenLoud  act = whenLoud' act $ return ()

-------------------------------------------------------------------------------
whenLoud' :: TCM r a -> TCM r a -> TCM r a
-------------------------------------------------------------------------------
whenLoud' loud other = do  v <- tc_verb <$> get
                           case v of
                             V.Loud -> loud
                             _      -> other

-------------------------------------------------------------------------------
whenQuiet :: TCM r () -> TCM r ()
-------------------------------------------------------------------------------
whenQuiet  act = whenQuiet' act $ return ()

-------------------------------------------------------------------------------
whenQuiet' :: TCM r a -> TCM r a -> TCM r a
-------------------------------------------------------------------------------
whenQuiet' quiet other = do  tc_verb <$> get >>= \case
                               V.Quiet -> quiet
                               _       -> other

getOpts :: TCM r Config
getOpts = tc_opts <$> get

getAstCount :: TCM r NodeId
getAstCount = tc_ast_cnt <$> get


-------------------------------------------------------------------------------
-- | Substitutions
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
getSubst :: TCM r (RSubst r)
-------------------------------------------------------------------------------
getSubst = tc_subst <$> get

-------------------------------------------------------------------------------
setSubst   :: RSubst r -> TCM r ()
-------------------------------------------------------------------------------
setSubst θ = modify $ \st -> st { tc_subst = θ }

-------------------------------------------------------------------------------
addSubst :: (Unif r, IsLocated a) => a -> RSubst r -> TCM r ()
-------------------------------------------------------------------------------
addSubst l θ = do
    θ0 <- appSu θ <$> getSubst
    case θ0 <=> θ of
      [] -> return ()
      ts -> forM_ ts $ \(t1,t2) -> tcError $ errorMergeSubst (srcPos l) t1 t2
    setSubst $ θ0 `mappend` θ
  where
    inList f        = fromList . f . toList
    appSu           = inList . fmap . mapSnd . apply
    Su m <=> Su m'  = catMaybes $ chk <$> M.toList (M.intersectionWith (,) m m')
    chk (k, (t,t')) | uninstantiated k t = Nothing
                    | t == t' = Nothing
                    | otherwise = Just (t,t')

    uninstantiated k t    = TVar k fTop `eqV` t

-------------------------------------------------------------------------------
extSubst :: (F.Reftable r, PP r) => [TVar] -> TCM r ()
-------------------------------------------------------------------------------
extSubst βs = getSubst >>= setSubst . (`mappend` θ)
  where
    θ       = fromList $ zip βs (tVar <$> βs)


-------------------------------------------------------------------------------
-- | Error handling
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
tcError     :: Error -> TCM r a
-------------------------------------------------------------------------------
tcError err = throwE $ catMessage err "TC-ERROR\n"

-------------------------------------------------------------------------------
tcWrap :: TCM r a -> TCM r (Either Error a)
-------------------------------------------------------------------------------
tcWrap act = (Right <$> act) `catchError` (return . Left)

-------------------------------------------------------------------------------
logError   :: Error -> a -> TCM r a
-------------------------------------------------------------------------------
logError err x = modify (\st -> st { tc_errors = err : tc_errors st}) >> return x

-------------------------------------------------------------------------------
freshTyArgs :: Unif r => AnnSSA r -> Int -> IContext -> [TVar] -> RType r -> TCM r (RType r)
-------------------------------------------------------------------------------
freshTyArgs a n ξ αs t = (`apply` t) <$> freshSubst a n ξ αs

-------------------------------------------------------------------------------
freshSubst :: Unif r => AnnSSA r -> Int -> IContext -> [TVar] -> TCM r (RSubst r)
-------------------------------------------------------------------------------
freshSubst (FA i l _) n ξ αs
  = do when (not $ unique αs) $ logError (errorUniqueTypeParams l) ()
       βs        <- mapM (freshTVar l) αs
       setTyArgs l i n ξ βs
       extSubst   $ βs
       return     $ fromList $ zip αs (tVar <$> βs)

-------------------------------------------------------------------------------
setTyArgs :: (IsLocated l, Unif r) => l -> NodeId -> Int -> IContext -> [TVar] -> TCM r ()
-------------------------------------------------------------------------------
setTyArgs _  i n ξ βs
  = case map tVar βs of
      [] -> return ()
      vs -> addAnn i $ TypInst n ξ vs


-------------------------------------------------------------------------------
-- | Managing Annotations: Type Instantiations
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
getAnns :: (F.Reftable r, Substitutable r (Fact r)) => TCM r (AnnInfo r)
-------------------------------------------------------------------------------
getAnns = do θ     <- tc_subst <$> get
             m     <- tc_anns  <$> get
             let m' = fmap (apply θ {-. sortNub-}) m
             _     <- modify $ \st -> st { tc_anns = m' }
             return m'

-------------------------------------------------------------------------------
addAnn :: Unif r => NodeId -> Fact r -> TCM r ()
-------------------------------------------------------------------------------
addAnn i f = modify $ \st -> st { tc_anns = I.insertWith (++) i [f] $ tc_anns st }

-------------------------------------------------------------------------------
execute ::  Unif r => Config -> V.Verbosity -> TcRsc r -> TCM r a -> Either (F.FixResult Error) a
-------------------------------------------------------------------------------
execute cfg verb pgm act
  = case runState (runExceptT act) $ initState cfg verb pgm of
      (Left err, _) -> Left $ F.Unsafe [err]
      (Right x, st) -> applyNonNull (Right x) (Left . F.Unsafe) (reverse $ tc_errors st)

-------------------------------------------------------------------------------
initState :: Unif r => Config -> V.Verbosity -> TcRsc r -> TCState r
-------------------------------------------------------------------------------
initState cfg verb pgm = TCS tc_e tc_s tc_c tc_a tc_v tc_o tc_a_c
  where
    tc_e   = []
    tc_s   = mempty
    tc_c   = 0
    tc_a   = I.empty
    tc_v   = verb
    tc_o   = cfg
    tc_a_c = maxId pgm


--------------------------------------------------------------------------
-- | Generating Fresh Values
--------------------------------------------------------------------------

tick :: TCM r Int
tick = do st    <- get
          let n  = tc_cnt st
          put    $ st { tc_cnt = n + 1 }
          return n

class Freshable a where
  fresh :: a -> TCM r a

-- instance Freshable TVar where
--   fresh _ = TV . F.intSymbol "T" <$> tick

instance Freshable a => Freshable [a] where
  fresh = mapM fresh

freshTVar l _ =  ((`TV` l). F.intSymbol (F.symbol "T")) <$> tick

castPrefix        = "__cast_"
freshCastId l     =  Id l . (castPrefix ++) . show <$> tick
isCastId (Id _ s) = castPrefix `isPrefixOf` s


--------------------------------------------------------------------------------
-- | Unification and Subtyping
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
unifyTypesM :: Unif r => SrcSpan -> TCEnv r -> [RType r] -> [RType r] -> TCM r (RSubst r)
--------------------------------------------------------------------------------
unifyTypesM l γ t1s t2s
  | t1s |=| t2s
  = do  θ <- getSubst
        case unifys l γ θ t1s t2s of
          Left err -> tcError $ err
          Right θ' -> setSubst θ' >> return θ'
  | otherwise
  = tcError $ errorArgMismatch l
  where
    (|=|) = (==) `on` length

--------------------------------------------------------------------------------
unifyTypeM :: Unif r => SrcSpan -> TCEnv r -> RType r -> RType r -> TCM r (RSubst r)
--------------------------------------------------------------------------------
unifyTypeM l γ t t' = unifyTypesM l γ [t] [t']


--------------------------------------------------------------------------------
--  | Cast Helpers
--------------------------------------------------------------------------------

-- | @deadcastM@ wraps an expression @e@ with a dead-cast around @e@.
--------------------------------------------------------------------------------
deadcastM :: (Unif r) => IContext -> Error -> Expression (AnnSSA r) -> TCM r (Expression (AnnSSA r))
--------------------------------------------------------------------------------
deadcastM ξ err e
  = addCast ξ e $ CDead [err] tNull

-- | For the expression @e@, check the subtyping relation between the type @t1@
--   (the actual type for @e@) and @t2@ (the target type) and insert the cast.
--------------------------------------------------------------------------------
castM :: Unif r => TCEnv r -> Expression (AnnSSA r) -> RType r -> RType r -> TCM r (Expression (AnnSSA r))
--------------------------------------------------------------------------------
castM γ e t1 t2
  = case convert (srcPos e) γ t1 t2 of
      CNo   -> return e
      CUp{} -> return e
      CDn{} -> return e
      -- Only deadcasts add annotation now
      -- c   -> addCast (tce_ctx γ) e c

-- | Run the monad `a` in the current state. This action will not alter the
-- state.
--------------------------------------------------------------------------------
runFailM :: Unif r => TCM r a -> TCM r (Either Error a)
--------------------------------------------------------------------------------
runFailM a = fst . runState (runExceptT a) <$> get

--------------------------------------------------------------------------------
runMaybeM :: Unif r => TCM r a -> TCM r (Maybe a)
--------------------------------------------------------------------------------
runMaybeM a = runFailM a >>= \case
                Right rr -> return $ Just rr
                Left _   -> return $ Nothing

-- | subTypeM will throw error if subtyping fails
--------------------------------------------------------------------------------
subtypeM :: Unif r => SrcSpan -> TCEnv r -> RType r -> RType r -> TCM r ()
--------------------------------------------------------------------------------
subtypeM l γ t1 t2
  = case convert l γ t1 t2 of
      CNo     -> return  ()
      CUp _ _ -> return  ()
      _       -> tcError $ errorSubtype l t1 t2

addCast ξ e c = addAnn i fact >> wrapCast loc fact e
  where
    i         = fId  $ getAnnotation e
    loc       = fSrc $ getAnnotation e
    fact      = TCast ξ c

wrapCast _ f (Cast_ (FA i l fs) e) = Cast_ <$> freshenAnn (FA i l (f:fs)) <*> return e
wrapCast l f e                     = Cast_ <$> freshenAnn (FA (-1) l [f]) <*> return e

freshenAnn :: AnnSSA r -> TCM r (AnnSSA r)
freshenAnn (FA _ l a)
  = do n     <- tc_ast_cnt <$> get
       modify $ \st -> st {tc_ast_cnt = 1 + n}
       return $ FA n l a

-- | tcFunTys: "context-sensitive" function signature
--------------------------------------------------------------------------------
tcFunTys :: (Unif r, F.Subable (RType r), F.Symbolic s, PP a)
         => AnnSSA r -> a -> [s] -> RType r -> TCM r [IOverloadSig r]
--------------------------------------------------------------------------------
tcFunTys l f xs ft = either tcError return sigs
  where
    sigs | Just ts <- bkFuns ft
         = case partitionEithers [funTy t | t <- ts] of
             ([], fts) -> Right $ zip ([0..] :: [Int]) fts
             (_ , _  ) -> Left  $ errorArgMismatch (srcPos l)
         | otherwise
         = Left $ errorNonFunction (srcPos l) f ft

    funTy (αs, yts, t) | Just yts' <- padUndefineds xs yts
                       = let (su, ts') = renameBinds yts' in
                         Right $ (αs, ts', F.subst su t)
                       | otherwise
                       = Left  $ errorArgMismatch (srcPos l)

    renameBinds yts = (su, [B x $ F.subst su ty | B x ty <- yts])
      where
        su          = F.mkSubst suL
        suL         = safeZipWith "renameBinds" fSub yts xs
        fSub yt x   = (b_sym yt, F.eVar x)

--------------------------------------------------------------------------------
checkTypes :: Unif r => ClassHierarchy r -> TCM r ()
--------------------------------------------------------------------------------
checkTypes cha = mapM_ (\(_,ts) -> mapM_ (safeExtends cha) ts) types
  where
    types     = mapSnd (envToList . m_types) <$> qenvToList (cModules cha)

-- TODO | Checks:
-- TODO
-- TODO   * Overwriten types safely extend the previous ones
-- TODO
-- TODO   * [TODO] No conflicts between inherited types
-- TODO
--------------------------------------------------------------------------------
safeExtends :: (IsLocated l, Unif r) => ClassHierarchy r -> (l, TypeDecl r) -> TCM r ()
--------------------------------------------------------------------------------
safeExtends _ _ = return ()
-- safeExtends cha (l, t@(TD (TS k (BGen c bvs) ([p],_)) _))
--   = safeExtends1 cha l c (typeMemersOfTDecl cha t) p
--
-- safeExtends1 cha l c ms (Gen n ts)
--   | Just td <- resolveType cha n
--   -- , Just ns <- expand' γ td ts
--   = return ()
--   -- = if isSubtype γ (mkTCons tImm ms) (mkTCons tImm ns)
--   --     then return ()
--   --     else tcError $ errorClassExtends (srcPos l) c p (mkTCons ms) (mkTCons ns)
--   | otherwise
--   = tcError $ bugExpandType (srcPos l) n
--   where
--     mkTCons m es = TObj es fTop

-- Local Variables:
-- flycheck-disabled-checkers: (haskell-liquid)
-- End:
