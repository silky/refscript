{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverlappingInstances      #-}
{-# LANGUAGE TupleSections             #-}

-- | Top Level for Refinement Type checker
module Language.Nano.Liquid.Liquid (verifyFile) where

import           Control.Applicative               ((<$>), (<*>))
import           Control.Exception                 (throw)
import           Control.Monad

import           Data.Function                     (on)
import qualified Data.HashMap.Strict               as HM
import qualified Data.HashSet                      as HS
import           Data.List                         (sortBy)
import qualified Data.Map.Strict                   as M
import           Data.Maybe                        (catMaybes, fromMaybe,
                                                    maybeToList)
import qualified Data.Traversable                  as T

import           Language.Nano.Syntax
import           Language.Nano.Syntax.Annotations
import           Language.Nano.Syntax.PrettyPrint

import qualified Language.Fixpoint.Config          as C
import           Language.Fixpoint.Errors
import           Language.Fixpoint.Interface       (solve)
import           Language.Fixpoint.Misc
import qualified Language.Fixpoint.Names           as N
import qualified Language.Fixpoint.Types           as F

import qualified Data.Text                         as T
import           Language.Nano.Annots
import           Language.Nano.CmdLine             (Config)
import qualified Language.Nano.Env                 as E
import           Language.Nano.Errors
import           Language.Nano.Liquid.CGMonad
import           Language.Nano.Liquid.Types
import           Language.Nano.Locations
import           Language.Nano.Misc                (mseq)
import           Language.Nano.Names
import           Language.Nano.Program
import           Language.Nano.SSA.SSA
import qualified Language.Nano.SystemUtils         as A
import           Language.Nano.Typecheck.Lookup
import           Language.Nano.Typecheck.Parse
import           Language.Nano.Typecheck.Resolve
import           Language.Nano.Typecheck.Subst
import           Language.Nano.Typecheck.Typecheck (typeCheck)
import           Language.Nano.Typecheck.Types
import           Language.Nano.Types
import           Language.Nano.Visitor
import           System.Console.CmdArgs.Default

import qualified Data.Foldable                     as FO
import           Debug.Trace                       (trace)
import           Text.PrettyPrint.HughesPJ

type PPRS r = (PPR r, Substitutable r (Fact r))

--------------------------------------------------------------------------------
verifyFile    :: Config -> FilePath -> [FilePath] -> IO (A.UAnnSol RefType, F.FixResult Error)
--------------------------------------------------------------------------------
verifyFile cfg f fs = parse     fs
                    $ ssa
                    $ tc    cfg
                    $ refTc cfg f

parse fs next
  = do  r <- parseNanoFromFiles fs
        donePhase Loud "Parse Files"
        nextPhase r next

ssa next p
  = do  r <- ssaTransform p
        donePhase Loud "SSA Transform"
        nextPhase r next

tc cfg next p
  = do  r <- typeCheck cfg p
        donePhase Loud "Typecheck"
        nextPhase r next

refTc cfg f p
  = do donePhase Loud "Generate Constraints"
       solveConstraints p f cgi
  where
    -- cgi = generateConstraints cfg $ trace (show (ppCasts p)) p
    cgi = generateConstraints cfg p

nextPhase (Left l)  _    = return (A.NoAnn, l)
nextPhase (Right x) next = next x

ppCasts (Nano { code = Src fs }) =
  fcat $ pp <$> [ (srcPos a, c) | a <- concatMap FO.toList fs
                                , TCast _ c <- ann_fact a ]

-- | solveConstraints
--   Call solve with `ueqAllSorts` enabled.
--------------------------------------------------------------------------------
solveConstraints :: NanoRefType
                 -> FilePath
                 -> CGInfo
                 -> IO (A.UAnnSol RefType, F.FixResult Error)
--------------------------------------------------------------------------------
solveConstraints p f cgi
  = do (r, s)  <- solve fpConf f [] $ cgi_finfo cgi
       let r'   = fmap (ci_info . F.sinfo) r
       let ann  = cgi_annot cgi
       let sol  = applySolution s
       return (A.SomeAnn ann sol, r')
  where
    fpConf      = C.withUEqAllSorts def { C.real = real } True
    real        = RealOption `elem` pOptions p

--------------------------------------------------------------------------------
applySolution :: F.FixSolution -> A.UAnnInfo RefType -> A.UAnnInfo RefType
--------------------------------------------------------------------------------
applySolution = fmap . fmap . tx
  where
    tx s (F.Reft (x, zs))   = F.Reft (x, F.squishRefas (appSol s <$> zs))
    appSol _ ra@(F.RConc _) = ra
    appSol s (F.RKvar k su) = F.RConc $ F.subst su $ HM.lookupDefault F.PTop k s

--------------------------------------------------------------------------------
generateConstraints :: Config -> NanoRefType -> CGInfo
--------------------------------------------------------------------------------
generateConstraints cfg pgm = getCGInfo cfg pgm $ consNano pgm

--------------------------------------------------------------------------------
consNano :: NanoRefType -> CGM ()
--------------------------------------------------------------------------------
consNano p@(Nano {code = Src fs})
  = do  g   <- initGlobalEnv p
        consStmts g fs
        return ()


-------------------------------------------------------------------------------
-- | Initialize environment
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
initGlobalEnv  :: NanoRefType -> CGM CGEnv
-------------------------------------------------------------------------------
initGlobalEnv pgm@(Nano { code = Src s })
      = freshenCGEnvM (CGE nms bds grd ctx mod cha pth Nothing cst)
    >>= envAdds "initGlobalEnv" extras
  where
    reshuffle1 = \(_,_,c,d,e) -> (d,c,e)
    reshuffle2 = \(_,c,d,e)   -> (d,c,e)
    nms        = E.envUnion
                 (E.envAdds extras    $ E.envMap reshuffle1
                                      $ mkVarEnv $ visibleVars s)
                 (E.envMap reshuffle2 $ E.envUnionList $ maybeToList
                                      $ m_variables <$> E.qenvFindTy pth mod)

    extras     = [(Id (srcPos dummySpan) "undefined", undefInfo)]
    undefInfo  = (TApp TUndef [] F.trueReft, ReadOnly, Initialized)
    bds        = F.emptyIBindEnv
    cha        = pCHA pgm
    grd        = []
    mod        = pModules pgm
    ctx        = emptyContext
    pth        = mkAbsPath []
    cst        = consts pgm

-------------------------------------------------------------------------------
initModuleEnv :: (F.Symbolic n, PP n) => CGEnv -> n -> [Statement AnnTypeR] -> CGM CGEnv
-------------------------------------------------------------------------------
initModuleEnv g n s
  = freshenCGEnvM $ CGE nms bds grd ctx mod cha pth (Just g) cst
  where
    reshuffle1 = \(_,_,c,d,e) -> (d,c,e)
    reshuffle2 = \(_,c,d,e)   -> (d,c,e)
    nms        = (E.envMap reshuffle1 $ mkVarEnv $ visibleVars s) `E.envUnion`
                 (E.envMap reshuffle2 $ E.envUnionList $ maybeToList
                                      $ m_variables <$> E.qenvFindTy pth mod)
    bds        = cge_fenv g
    grd        = []
    mod        = cge_mod g
    cha        = cge_cha g
    ctx        = emptyContext
    pth        = extendAbsPath (cge_path g) n
    cst        = cge_consts g

-- | `initFuncEnv l f i xs (αs, ts, t) g`
--
--    * Pushes a new context @i@
--    * Adds return type @t@
--    * Adds binders for the type variables @αs@
--    * Adds binders for the arguments @ts@
--    * Adds binder for the 'arguments' variable
--
initFuncEnv l f i xs (αs,thisTO,ts,t) g s =
        envAdds ("init-func-" ++ ppshow f ++ "-0") varBinds g'
    >>= envAdds ("init-func-" ++ ppshow f ++ "-1") tyBinds
    >>= envAdds ("init-func-" ++ ppshow f ++ "-3") argBind
    >>= envAdds ("init-func-" ++ ppshow f ++ "-4") thisBind       -- FIXME: this might be included in varBinds
    >>= envAddReturn f t
    >>= freshenCGEnvM
  where
    g'        = CGE nms fenv grds ctx mod cha pth parent cst
    nms       = E.envMap (\(_,_,c,d,e) -> (d,c,e)) $ mkVarEnv $ visibleVars s
    fenv      = cge_fenv g
    grds      = []
    mod       = cge_mod g
    cha       = cge_cha g
    ctx       = pushContext i (cge_ctx g)
    pth       = cge_path g
    parent    = Just g
    cst       = cge_consts g
    tyBinds   = [(Loc (srcPos l) α, (tVar α, ReadOnly, Initialized)) | α <- αs]
    varBinds  = zip (fmap ann <$> xs) $ (,WriteLocal,Initialized) <$> ts
    argBind   = ( argSym, (argTy, ReadOnly, Initialized))
              : [ (mkQualSym argSym f, (t,ReadOnly, Initialized)) | (f,t) <- immFields g argTy ]
    argSym    = F.symbol $ argId l
    argTy     = mkArgTy l ts $ cge_names g

    thisBind  = (builtinOpId BIThis,) . (, ReadOnly, Initialized) <$> maybeToList thisTO


-------------------------------------------------------------------------------
-- | Environment wrappers
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
consEnvFindTypeDefM :: IsLocated a => a -> CGEnv -> AbsName -> CGM (IfaceDef F.Reft)
-------------------------------------------------------------------------------
consEnvFindTypeDefM l γ x
  = case resolveTypeInEnv γ x of
      Just t  -> return t
      Nothing -> die $ bugClassDefNotFound (srcPos l) x


-------------------------------------------------------------------------------
-- | Constraint generation
-------------------------------------------------------------------------------

--------------------------------------------------------------------------------
consFun :: CGEnv -> Statement (AnnType F.Reft) -> CGM CGEnv
--------------------------------------------------------------------------------
consFun g (FunctionStmt l f xs body)
  = case envFindTy f g of
      Just spec -> do ft        <- cgFunTys l f xs spec
                      forM_ ft   $ consFun1 l g f xs body
                      return     $ g
      Nothing   -> cgError $ errorMissingSpec (srcPos l) f

consFun _ s
  = die $ bug (srcPos s) "consFun called not with FunctionStmt"

-- | @consFun1@ checks a function body against a *one* of multiple
--   conjuncts of an overloaded (intersection) type signature.
--   Assume: len ts' = len xs

consFun1 l g f xs body (i, ft)
  = initFuncEnv l f i xs ft g body >>= (`consStmts` body)


--------------------------------------------------------------------------------
consStmts :: CGEnv -> [Statement AnnTypeR]  -> CGM (Maybe CGEnv)
--------------------------------------------------------------------------------
consStmts g stmts = consFold consStmt g stmts


--------------------------------------------------------------------------------
consStmt :: CGEnv -> Statement AnnTypeR -> CGM (Maybe CGEnv)
--------------------------------------------------------------------------------

-- | @consStmt g s@ returns the environment extended with binders that are
--   due to the execution of statement s. @Nothing@ is returned if the
--   statement has (definitely) hit a `return` along the way.

-- skip
consStmt g (EmptyStmt _)
  = return $ Just g

-- x = e
consStmt g (ExprStmt l (AssignExpr _ OpAssign (LVar lx x) e))
  = consAsgn l g (Id lx x) e

-- e1.f = e2
consStmt g (ExprStmt l (AssignExpr _ OpAssign (LDot _ e1 f) e2))
  = mseq (consExpr g e1 Nothing) $ \(x1,g') -> do
      t         <- safeEnvFindTy x1 g'
      let rhsCtx = fmap snd3 $ getProp g' FieldAccess Nothing f t
      opTy      <- setPropTy l (F.symbol f) <$> safeEnvFindTy (builtinOpId BISetProp) g'
      fmap snd <$> consCall g' l BISetProp (FI Nothing [(vr x1, Nothing),(e2, rhsCtx)]) opTy
  where
      vr         = VarRef $ getAnnotation e1

-- e
consStmt g (ExprStmt _ e)
  = fmap snd <$> consExpr g e Nothing

-- s1;s2;...;sn
consStmt g (BlockStmt _ stmts)
  = consStmts g stmts

-- if b { s1 }
consStmt g (IfSingleStmt l b s)
  = consStmt g (IfStmt l b s (EmptyStmt l))

--  1. Use @envAddGuard True@ and @envAddGuard False@ to add the binder
--     from the condition expression @e@ into @g@ to obtain the @CGEnv@
--     for the "then" and "else" statements @s1@ and @s2 respectively.
--  2. Recursively constrain @s1@ and @s2@ under the respective environments.
--  3. Combine the resulting environments with @envJoin@

-- if e { s1 } else { s2 }
consStmt g (IfStmt l e s1 s2) =
  mseq (safeEnvFindTy (builtinOpId BITruthy) g
            >>= consCall g l "truthy" (FI Nothing [(e, Nothing)])) $ \(xe,ge) -> do
    g1'      <- (`consStmt` s1) $ envAddGuard xe True ge
    g2'      <- (`consStmt` s2) $ envAddGuard xe False ge
    envJoin l g g1' g2'

-- while e { s }
consStmt g (WhileStmt l e s)
  = consWhile g l e s

-- var x1 [ = e1 ]; ... ; var xn [= en];
consStmt g (VarDeclStmt _ ds)
  = consFold consVarDecl g ds

-- return
consStmt g (ReturnStmt l Nothing)
  = do _ <- subType l (errorLiquid' l) g tVoid (envFindReturn g)
       return Nothing

-- return e
consStmt g (ReturnStmt l (Just e@(VarRef lv x)))
  | Just t <- envFindTy x g, needsCall t
  = do  g'    <- envAdd fn (finalizeTy t,ReadOnly,Initialized) g
        consStmt g' (ReturnStmt l (Just (CallExpr l (VarRef lv fn) [e])))
  | otherwise
  = do  _ <- consCall g l "return" (FI Nothing [(e, Just retTy)]) $ returnTy retTy True
        return Nothing
  where
    retTy = envFindReturn g
    fn    = Id l "__finalize__"
    needsCall (TRef _ (m:_) _) = isUniqueMutable m
    needsCall _                = False

consStmt g (ReturnStmt l (Just e))
  = do  _ <- consCall g l "return" (FI Nothing [(e, Just retTy)]) $ returnTy retTy True
        return Nothing
  where
    retTy = envFindReturn g

-- throw e
consStmt g (ThrowStmt _ e)
  = consExpr g e Nothing >> return Nothing

-- (overload) function f(x1...xn);
consStmt g (FuncOverload _ _ _ ) = return $ Just g

-- declare function f(x1...xn);
consStmt g (FuncAmbDecl _ _ _ ) = return $ Just g

-- function f(x1...xn){ s }
consStmt g s@(FunctionStmt _ _ _ _)
  = Just <$> consFun g s

--
-- class A<V> [extends B<T>] {..}
--
--  * Add the type vars V in the environment
--
--  * Compute type for "this" and add that to the env as well.
--
consStmt g (ClassStmt l x _ _ ce)
  = do  dfn      <- consEnvFindTypeDefM l g rn
        g'       <- envAdds "consStmt-class-0"
                      [(Loc (ann l) α, (tVar α, WriteGlobal,Initialized))
                          | α <- t_args dfn] g
        consClassElts l g' dfn ce
        return    $ Just g
  where
    rn            = QN AK_ (srcPos l) ss (F.symbol x)
    QP AK_ _ ss   = cge_path g

consStmt g (IfaceStmt _ _)
  = return $ Just g

consStmt g (EnumStmt _ _ _)
  = return $ Just g

consStmt g (ModuleStmt _ n body)
  = initModuleEnv g n body >>= (`consStmts` body) >> return (Just g)

-- OTHER (Not handled)
consStmt _ s
  = errorstar $ "consStmt: not handled " ++ ppshow s


------------------------------------------------------------------------------------
consVarDecl :: CGEnv -> VarDecl AnnTypeR -> CGM (Maybe CGEnv)
------------------------------------------------------------------------------------
consVarDecl g v@(VarDecl l x (Just e))
  = case scrapeVarDecl v of
      -- | Local
      [ ] ->
        mseq (consExpr g e Nothing) $ \(y,gy) -> do
          t       <- safeEnvFindTy y gy
          Just   <$> envAdds "consVarDecl" [(x, (t, WriteLocal, Initialized))] gy

      [(_, WriteLocal, Just t)] ->
        mseq (consCall g l "consVarDecl" (FI Nothing [(e, Nothing)]) $ localTy t) $ \(y,gy) -> do
          t       <- safeEnvFindTy y gy
          Just   <$> envAdds "consVarDecl" [(x, (t, WriteLocal, Initialized))] gy

      [(_, WriteLocal, Nothing)] ->
        mseq (consExpr g e Nothing) $ \(y,gy) -> do
          t       <- safeEnvFindTy y gy
          Just   <$> envAdds "consVarDecl" [(x, (t, WriteLocal, Initialized))] gy

      -- | Global
      [(_, WriteGlobal, Just t)] ->
        mseq (consExpr g e $ Just t) $ \(y, gy) -> do
          ty      <- safeEnvFindTy y gy
          fta     <- freshenType WriteGlobal gy l t
          _       <- subType l (errorLiquid' l) gy ty  fta
          _       <- subType l (errorLiquid' l) gy fta t
          Just   <$> envAdd x (fta, WriteGlobal, Initialized) gy

      [(_, WriteGlobal, Nothing)] ->
        mseq (consExpr g e Nothing) $ \(y, gy) -> do
          ty      <- safeEnvFindTy y gy
          fta     <- refresh ty >>= wellFormed l g
          _       <- subType l (errorLiquid' l) gy ty fta
          Just   <$> envAdd x (fta, WriteGlobal, Initialized) gy

      -- | ReadOnly
      [(_, ReadOnly, Just t)] ->
        mseq (consCall g l "consVarDecl" (FI Nothing [(e, Nothing)]) $ localTy t) $ \(y,gy) -> do
          t       <- safeEnvFindTy y gy
          Just   <$> envAdds "consVarDecl" [(x, (t, ReadOnly, Initialized))] gy

      [(_, ReadOnly, Nothing)] ->
        mseq (consExpr g e Nothing) $ \(y,gy) -> do
          t       <- safeEnvFindTy y gy
          Just   <$> envAdds "consVarDecl" [(x, (t, ReadOnly ,Initialized))] gy

      _ -> cgError $ errorVarDeclAnnot (srcPos l) x

consVarDecl g v@(VarDecl l x Nothing)
  = case scrapeVarDecl v of
      -- special case ambient vars
      [(AmbVarDeclKind, _, Just t)] ->
        Just <$> envAdds "consVarDecl" [(x, (t, ReadOnly, Initialized))] g
      -- The rest should have fallen under the 'undefined' initialization case
      _ -> error "LQ: consVarDecl this shouldn't happen"

------------------------------------------------------------------------------------
consExprT :: AnnTypeR -> CGEnv -> Expression AnnTypeR -> Maybe RefType
          -> CGM (Maybe (Id AnnTypeR, CGEnv))
------------------------------------------------------------------------------------
consExprT _ g e Nothing  = consExpr g e Nothing
consExprT l g e (Just t) = consCall  g l "consExprT" (FI Nothing [(e, Nothing)])
                         $ TFun Nothing [B (F.symbol "x") t] tVoid fTop

------------------------------------------------------------------------------------
consClassElts :: IsLocated l => l -> CGEnv -> IfaceDef F.Reft -> [ClassElt AnnTypeR] -> CGM ()
------------------------------------------------------------------------------------
consClassElts l g d@(ID nm _ vs _ es) cs
  = do  g0   <- envAdds "consClassElts-2" thisInfo g
        g1   <- envAdds "consClassElts-1" fs g0  -- Add imm fields into scope beforehand
        mapM_ (consClassElt g1 d) cs
  where
    fs = [ (ql f,(t,ro,ii)) | ((_,im), (FieldSig f _ m t)) <- M.toList es
                            , isImmutable m ]
    -- TODO: Make location more precise
    --
    -- PV: qualified name here used as key -> ok
    ql        = mkQualSym $ F.symbol $ builtinOpId BIThis
    im        = InstanceMember
    ro        = ReadOnly
    ii        = Initialized
    this_t    = TRef nm (tVar <$> vs) fTop
    thisInfo  = [(this,(this_t,ReadOnly,Initialized))]
    this      = Loc (srcPos l) $ builtinOpId BIThis

------------------------------------------------------------------------------------
consClassElt :: CGEnv -> IfaceDef F.Reft -> ClassElt AnnTypeR -> CGM ()
------------------------------------------------------------------------------------
consClassElt g d@(ID nm _ vs _ ms) (Constructor l xs body)
  = do  g0       <- envAdd ctorExit (mkCtorExitTy, ReadOnly, Initialized) g
        g1       <- envAdds "classElt-ctor-1" superInfo g0
        ts       <- cgFunTys l ctor xs ctorTy
        forM_ ts  $ consFun1 l g1 ctor xs body
  where
    --
    -- 'this' will not appear in the code but it might
    -- appear in refinements so add in scope
    --
    this_t        = TRef nm (tVar <$> vs) fTop
    thisInfo      = [(this, (this_t, ReadOnly, Initialized))]

    this          = Loc (srcPos l) $ builtinOpId BIThis
    ctor          = Loc (srcPos l) $ builtinOpId BICtor
    ctorExit      = Loc (srcPos l) $ builtinOpId BICtorExit
    super         = Loc (srcPos l) $ builtinOpId BISuper

    superInfo     | Just t <- extractParent'' g d
                  = [(super,(t,ReadOnly,Initialized))]
                  | otherwise
                  = []
    --
    -- * Keep the right order of fields
    --
    -- * Make the return object immutable to avoid contra-variance
    --   checks at the return from the constructor.
    --
    -- * Exclude __proto__ field
    --
    mkCtorExitTy  = mkFun (vs, Nothing, bs,
                           this_t `nubstrengthen` F.Reft (F.vv Nothing, fbind <$> out))
      where
        bs        | Just (TCons _ ms _) <- expandType Coercive g this_t
                  = sortBy c_sym [ B f t' | ((_,InstanceMember),(FieldSig f _ m t)) <- M.toList ms
                                          , F.symbol f /= F.symbol "__proto__"
                                          , let t' = unqualifyThis g this_t t ]
                  | otherwise
                  = []
        out       | Just (TCons _ ms _) <- expandType Coercive g this_t
                  = [ f | ((_,InstanceMember),(FieldSig f _ m t)) <- M.toList ms
                        , isImmutable m, F.symbol f /= F.symbol "__proto__" ]
                  | otherwise
                  = []

    fbind f       = F.RConc $ F.PAtom F.Ueq (mkOffset v_sym $ F.symbolString f) (F.eVar f)
    -- fbind f       = F.RConc $ F.PAtom F.Eq (F.eVar $ F.symbol "this" `F.qualifySymbol` f) (F.eVar f)

    v_sym         = F.symbol $ F.vv Nothing
    c_sym         = on compare b_sym

    -- This works now cause each class is required to have a constructor
    ctorTy        = mkAnd [mkAll vs $ remThisBinding t | ConsSig t <- M.elems ms ]

-- | Static field
consClassElt g dfn (MemberVarDecl l True x (Just e))
  | Just (FieldSig _ _ _ t) <- spec
  = void $ consCall g l "field init"  (FI Nothing [(e, Just t)]) (mkInitFldTy t)
  | otherwise
  = cgError $ errorClassEltAnnot (srcPos l) (t_name dfn) x
  where
    spec      = M.lookup (F.symbol x, StaticMember) (t_elts dfn)

consClassElt _ _ (MemberVarDecl l True x Nothing)
  = cgError $ unsupportedStaticNoInit (srcPos l) x

-- | Instance variable (checked at ctor)
consClassElt g dfn (MemberVarDecl _ False _ Nothing)
  = return ()

consClassElt _ _ (MemberVarDecl l False x _)
  = die $ bugClassInstVarInit (srcPos l) x

-- | Static method
consClassElt g dfn (MemberMethDef l True x xs body)
  | Just (MethSig _ t) <- M.lookup (F.symbol x,StaticMember) (t_elts dfn)
  = do  its <- cgFunTys l x xs t
        mapM_ (consFun1 l g x xs body) its
  | otherwise
  = cgError  $ errorClassEltAnnot (srcPos l) (t_name dfn) x

-- | Instance method
consClassElt g (ID nm _ vs _ es) (MemberMethDef l False x xs body)
  | Just (MethSig _ t) <- M.lookup (F.symbol x, InstanceMember) es
  = do  ft     <- cgFunTys l x xs t
        mapM_     (consFun1 l g x xs body) $ mapSnd procFT <$> ft

  | otherwise
  = cgError  $ errorClassEltAnnot (srcPos l) nm x

  where

    procFT (ws,so,xs,y)   = (ws, Just this_t, xs, y)
      where this_t        = slf so
            slf (Just (TSelf m))  = mkThis (toType m) vs
            slf (Just t)          = t
            slf Nothing           = mkThis t_readOnly vs

    mkThis m (_:αs)       = TRef an (ofType m : map tVar αs) fTop
    mkThis _ _            = throw $ bug (srcPos l) "Liquid.Liquid.consClassElt MemberMethDef"

    an                    = QN AK_ (srcPos l) ss (F.symbol nm)

    QP AK_ _ ss           = cge_path g

consClassElt _ _  (MemberMethDecl _ _ _ _) = return ()


--------------------------------------------------------------------------------
consAsgn :: AnnTypeR -> CGEnv -> Id AnnTypeR -> Expression AnnTypeR -> CGM (Maybe CGEnv)
--------------------------------------------------------------------------------
consAsgn l g x e =
  case envFindTyForAsgn x g of
    -- This is the first time we initialize this variable
    Just (t, WriteGlobal, Uninitialized) ->
      do  t' <- freshenType WriteGlobal g l t
          mseq (consExprT l g e $ Just t') $ \(_, g') -> do
            g'' <- envAdds "consAsgn-0" [(x,(t', WriteGlobal, Initialized))] g'
            return $ Just g''

    Just (t,WriteGlobal,_) -> mseq (consExprT l g e $ Just t) $ \(_, g') ->
                                return    $ Just g'
    Just (t,a,i)           -> mseq (consExprT l g e $ Just t) $ \(x', g') -> do
                                t        <- safeEnvFindTy x' g'
                                Just    <$> envAdds "consAsgn-1" [(x,(t,a,i))] g'
    Nothing                -> mseq (consExprT l g e Nothing) $ \(x', g') -> do
                                t        <- safeEnvFindTy x' g'
                                Just    <$> envAdds "consAsgn-1" [(x,(t,WriteLocal, Initialized))] g'


-- | @consExpr g e@ returns a pair (g', x') where x' is a fresh,
-- temporary (A-Normalized) variable holding the value of `e`,
-- g' is g extended with a binding for x' (and other temps required for `e`)
------------------------------------------------------------------------------------
consExpr :: CGEnv -> Expression AnnTypeR -> Maybe RefType -> CGM (Maybe (Id AnnTypeR, CGEnv))
------------------------------------------------------------------------------------
consExpr g (Cast_ l e) _ =
  case envGetContextCast g l of
    CDead e' t' -> consDeadCode g l e' t'
    CNo         -> mseq (consExpr g e Nothing) $ return . Just
    CUp t t'    -> mseq (consExpr g e Nothing) $ \(x,g') -> Just <$> consUpCast   g' l x t t'
    CDn t t'    -> mseq (consExpr g e Nothing) $ \(x,g') -> Just <$> consDownCast g' l x t t'

-- | < t > e
consExpr g ex@(Cast l e) _ =
  case [ ct | UserCast ct <- ann_fact l ] of
    [t] -> consCast g l e t
    _   -> die $ bugNoCasts (srcPos l) ex

consExpr g (IntLit l i) _
  = Just <$> envAddFresh l (tInt `eSingleton` i, WriteLocal, Initialized) g

-- Assuming by default 32-bit BitVector
consExpr g (HexLit l x) _
  | Just e <- bitVectorValue x
  = Just <$> envAddFresh l (tBV32 `nubstrengthen` e, WriteLocal, Initialized) g
  | otherwise
  = Just <$> envAddFresh l (tBV32, WriteLocal, Initialized) g

consExpr g (BoolLit l b) _
  = Just <$> envAddFresh l (pSingleton tBool b, WriteLocal, Initialized) g

consExpr g (StringLit l s) _
  = Just <$> envAddFresh l (tString `eSingleton` T.pack s, WriteLocal, Initialized) g

consExpr g (NullLit l) _
  = Just <$> envAddFresh l (tNull, WriteLocal, Initialized) g

consExpr g (ThisRef l) _
  = case envFindTyWithAsgn this g of
      Just _  -> return  $ Just (this,g)
      Nothing -> cgError $ errorUnboundId (ann l) "this"
  where
    this = Id l "this"

consExpr g (VarRef l x) _
  | Just (t,WriteGlobal,i) <- tInfo
  = Just <$> envAddFresh l (t,WriteLocal,i) g
  | Just (t,_,_) <- tInfo
  = addAnnot (srcPos l) x t >> return (Just (x, g))
  | otherwise
  = cgError $ errorUnboundId (ann l) x
  where
    tInfo = envFindTyWithAsgn x g

consExpr g (PrefixExpr l o e) _
  = do opTy         <- safeEnvFindTy (prefixOpId o) g
       consCall g l o (FI Nothing [(e,Nothing)]) opTy

consExpr g (InfixExpr l o@OpInstanceof e1 e2) _
  = mseq (consExpr g e2 Nothing) $ \(x, g') -> do
       t            <- safeEnvFindTy x g'
       case t of
         TClass x   -> do opTy <- safeEnvFindTy (infixOpId o) g
                          consCall g l o (FI Nothing ((,Nothing) <$> [e1, StringLit l2 (cc x)])) opTy
         _          -> cgError $ unimplemented (srcPos l) "tcCall-instanceof" $ ppshow e2
  where
    l2 = getAnnotation e2
    cc (QN AK_ _ _ s) = F.symbolString s

consExpr g (InfixExpr l o e1 e2) _
  = do opTy <- safeEnvFindTy (infixOpId o) g
       consCall g l o (FI Nothing ((,Nothing) <$> [e1, e2])) opTy

-- | e ? e1 : e2
consExpr g (CondExpr l e e1 e2) to
  = do  opTy    <- mkTy to <$> safeEnvFindTy (builtinOpId BICondExpr) g
        tt'     <- freshTyFun g l (rType tt)
        (v,g')  <- mapFst (VarRef l) <$> envAddFresh l (tt', WriteLocal, Initialized) g
        consCallCondExpr g' l BICondExpr
          (FI Nothing $ [(e,Nothing),(v,Nothing),(e1,rType <$> to),(e2,rType <$> to)])
          opTy
        -- consCallCondExpr g' l BICondExpr (FI Nothing ((,Nothing) <$> [e,v,e1,e2])) opTy
  where
    tt       = fromMaybe tTop to
    mkTy Nothing (TAll cv (TAll tv (TFun Nothing [B c_ tc, B t_ _   , B x_ xt, B y_ yt] o r))) =
                  TAll cv (TAll tv (TFun Nothing [B c_ tc, B t_ tTop, B x_ xt, B y_ yt] o r))
    mkTy _ t = t

-- | super(e1,..,en)
consExpr g (CallExpr l (SuperRef _) es) _
  | Just t            <- envFindTy (builtinOpId BIThis) g
  , Just (TRef x _ _) <- extractParent g t
  , Just ct           <- extractCtor g (TClass x)
  = consCall g l "super" (FI Nothing ((,Nothing) <$> es)) ct
  | otherwise
  = cgError $ errorUnboundId (ann l) "super"

-- | e.m(es)
consExpr g c@(CallExpr l em@(DotRef _ e f) es) _
  = mseq (consExpr g e Nothing) $ \(x,g') -> safeEnvFindTy x g' >>= go g' x
  where
             -- Variadic call error
    go g x t | isVariadicCall f, [] <- es
             = cgError $ errorVariadicNoArgs (srcPos l) em

             -- Variadic call
             | isVariadicCall f, v:vs <- es
             = consCall g l em (argsThis v vs) t

             -- Accessing and calling a function field
             --
             -- FIXME: 'this' should not appear in ft
             --        Add check for this.
             --
             | Just (_,ft,_) <- getProp g FieldAccess Nothing f t, isTFun ft
             = consCall g l c (args es) ft

             -- Invoking a method
             | Just (_,ft,_) <- getProp g MethodAccess Nothing f t
             = consCall g l c (argsThis (vr x) es) $ substThis g (x,t) ft

             | otherwise
             = cgError $ errorCallNotFound (srcPos l) e f

    isVariadicCall f = F.symbol f == F.symbol "call"
    args vs          = FI Nothing            ((,Nothing) <$> vs)
    argsThis v vs    = FI (Just (v,Nothing)) ((,Nothing) <$> vs)
    vr               = VarRef $ getAnnotation e

-- | e(es)
--
consExpr g (CallExpr l e es) _
  = mseq (consExpr g e Nothing) $ \(x, g') ->
      safeEnvFindTy x g' >>= consCall g' l e (FI Nothing ((,Nothing) <$> es))

-- | e.f
--
--   Returns type: { v: _ | v = x.f }, if e => x and `f` is an immutable field
--                 { v: _ | _       }, otherwise
--
--   The TC phase should have resolved whether we need to restrict the range of
--   the type of `e` (possibly adding a relevant cast). So no need to repeat the
--   call here.
--
consExpr g (DotRef l e f) to
  = mseq (consExpr g e Nothing) $ \(x,g') -> do
      te <- safeEnvFindTy x g'
      case getProp g' FieldAccess Nothing f te of
        --
        -- Special-casing Array.length
        --
        Just (TRef (QN _ _ [] s) _ _, _, _)
          | F.symbol "Array" == s && F.symbol "length" == F.symbol f ->
              consExpr g' (CallExpr l (DotRef l (vr x) (Id l "_get_length_")) []) to

        -- Do not nubstrengthen enumeration fields
        Just (TEnum _,t,_) -> Just <$> envAddFresh l (t,ReadOnly,Initialized) g'

        Just (_,t,m)       -> Just <$> envAddFresh l (mkTy m x te t,WriteLocal,Initialized) g'

        Nothing      -> cgError $  errorMissingFld (srcPos l) f te
  where
    vr         = VarRef $ getAnnotation e

    mkTy m x te t | isImmutable m  = fmap F.top t `nubstrengthen` F.usymbolReft (mkQualSym x f)
                  | otherwise      = substThis g (x,te) t

-- | e1[e2]
consExpr g e@(BracketRef l e1 e2) _
  = mseq (consExpr g e1 Nothing) $ \(x1,g') -> do
      opTy <- do  safeEnvFindTy x1 g' >>= \case
                    TEnum _ -> cgError $ unimplemented (srcPos l) msg e
                    _       -> safeEnvFindTy (builtinOpId BIBracketRef) g'
      consCall g' l BIBracketRef (FI Nothing ((,Nothing) <$> [vr x1, e2])) opTy
  where
    msg = "Support for dynamic access of enumerations"
    vr  = VarRef $ getAnnotation e1

-- | e1[e2] = e3
consExpr g (AssignExpr l OpAssign (LBracket _ e1 e2) e3) _
  = do  opTy <- safeEnvFindTy (builtinOpId BIBracketAssign) g
        consCall g l BIBracketAssign (FI Nothing ((,Nothing) <$> [e1,e2,e3])) opTy

-- | [e1,...,en]
consExpr g (ArrayLit l es) _
  = do  opTy <- arrayLitTy l (length es) <$> safeEnvFindTy (builtinOpId BIArrayLit) g
        consCall g l BIArrayLit (FI Nothing ((,Nothing) <$> es)) opTy

-- | {f1:e1,...,fn:en}
consExpr g (ObjectLit l bs) _
  = consCall g l "ObjectLit" (FI Nothing ((,Nothing) <$> es)) $ objLitTy l ps
  where
    (ps, es) = unzip bs

-- | new C(e, ...)
consExpr g (NewExpr l e es) _
  = mseq (consExpr g e Nothing) $ \(x,g') -> do
      t <- safeEnvFindTy x g'
      case extractCtor g t of
        Just ct -> consCall g l "constructor" (FI Nothing ((,Nothing) <$> es)) ct
        Nothing -> cgError $ errorConstrMissing (srcPos l) t

-- | super
consExpr g (SuperRef l) _
  = case envFindTy (builtinOpId BIThis) g of
      Just t   -> case extractParent g t of
                    Just tp -> Just <$> envAddFresh l (tp, WriteGlobal, Initialized) g
                    Nothing -> cgError $ errorSuper (ann l)
      Nothing  -> cgError $ errorSuper (ann l)

-- | function(xs) { }
consExpr g (FuncExpr l fo xs body) tCxtO
  = case anns of
      [ft] -> consFuncExpr ft
      _    -> case tCxtO of
                Just tCtx -> consFuncExpr tCtx
                Nothing   -> cgError $ errorNoFuncAnn $ srcPos l
  where
    consFuncExpr ft = do kft       <-  freshTyFun g l ft
                         fts       <-  cgFunTys l f xs kft
                         forM_ fts  $  consFun1 l g f xs body
                         Just      <$> envAddFresh l (kft, WriteLocal, Initialized) g

    anns            = [ t | FuncAnn t <- ann_fact l ]
    f               = maybe (F.symbol "<anonymous>") F.symbol fo

-- not handled
consExpr _ e _ = cgError $ unimplemented l "consExpr" e where l = srcPos  e


--------------------------------------------------------------------------------
consCast :: CGEnv -> AnnTypeR -> Expression AnnTypeR -> RefType -> CGM (Maybe (Id AnnTypeR, CGEnv))
--------------------------------------------------------------------------------
-- | Only freshen if TFun, otherwise the K-var will be instantiated with false
consCast g l e tc
  = do  opTy    <- safeEnvFindTy (builtinOpId BICastExpr) g
        tc'     <- freshTyFun g l (rType tc)
        (x,g')  <- envAddFresh l (tc', WriteLocal, Initialized) g
        consCall g' l "user-cast" (FI Nothing [(VarRef l x, Nothing),(e, Just tc')]) opTy

-- | Dead code
--   Only prove the top-level false.
consDeadCode g l e t
  = do subType l e g t tBot
       return Nothing
    where
       tBot = t `nubstrengthen` F.bot (rTypeR t)

-- | UpCast(x, t1 => t2)
consUpCast g l x _ t2
  = do (tx,a,i)  <- safeEnvFindTyWithAsgn x g
       ztx       <- zipTypeUpM g x tx t2
       envAddFresh l (ztx,a,i) g

-- | DownCast(x, t1 => t2)
consDownCast g l x _ t2
  = do (tx,a,i)  <- safeEnvFindTyWithAsgn x g
       txx       <- zipTypeUpM g x tx tx
       tx2       <- zipTypeUpM g x t2 tx
       ztx       <- zipTypeDownM g x tx t2
       subType l (errorDownCast (srcPos l) txx t2) g txx tx2
       envAddFresh l (ztx,a,i) g


-- | `consCall g l fn ets ft0`:
--
--   * @ets@ is the list of arguments, as pairs of expressions and optionally
--     contextual types on them.
--   * @ft0@ is the function's signature -- the 'this' argument should have been
--     made explicit by this point.
--
--------------------------------------------------------------------------------
consCall :: PP a
         => CGEnv
         -> AnnTypeR
         -> a
         -> FuncInputs (Expression AnnTypeR, Maybe RefType)
         -> RefType
         -> CGM (Maybe (Id AnnTypeR, CGEnv))
--------------------------------------------------------------------------------

--   1. Fill in @instantiateFTy@ to get a monomorphic instance of @ft@
--      i.e. the callee's RefType, at this call-site (You may want
--      to use @freshTyInst@)
--   2. Use @consExpr@ to determine types for arguments @es@
--   3. Use @subType@ to add constraints between the types from (step 2) and (step 1)
--   4. Use the @F.subst@ returned in 3. to substitute formals with actuals in output type of callee.

consCall g l fn ets ft0
  = mseq (consScan consExpr g ets) $ \(xes, g') -> do
      -- ts <- ltracePP l ("LQ " ++ ppshow fn) <$> T.mapM (`safeEnvFindTy` g') xes
      ts <- T.mapM (`safeEnvFindTy` g') xes
      case ol of
        -- If multiple are valid, pick the first one
        (ft:_) -> consInstantiate l g' fn ft ts xes
        _      -> cgError $ errorNoMatchCallee (srcPos l) fn (toType <$> ts) (toType <$> callSigs)
  where
    ol = [ lt | Overload cx t <- ann_fact l
              , cge_ctx g == cx
              , lt <- callSigs
              , arg_type (toType t) == arg_type (toType lt) ]
    callSigs  = extractCall g ft0
    arg_type t = (\(a,b,c,_) -> (a,b,c)) <$> bkFun t


balance (FI (Just to) ts) (FI Nothing fs)  = (FI (Just to) ts, FI (Just $ B (F.symbol "this") to) fs)
balance (FI Nothing ts)   (FI (Just _) fs) = (FI Nothing ts, FI Nothing fs)
balance ts                fs               = (ts, fs)

--------------------------------------------------------------------------------
consInstantiate :: PP a
                => AnnTypeR
                -> CGEnv
                -> a
                -> RefType                          -- Function spec
                -> FuncInputs RefType               -- Input types
                -> FuncInputs (Id AnnTypeR)         -- Input ids
                -> CGM (Maybe (Id AnnTypeR, CGEnv))
--------------------------------------------------------------------------------
consInstantiate l g fn ft ts xes
  = do  (_,its1,ot)     <- instantiateFTy l g fn ft
        ts1             <- idxMapFI (instantiateTy l g) 1 ts
        let (ts2, its2)  = balance ts1 its1
        (ts3, ot')      <- subNoCapture l (toList its2) (toList xes) ot
        _               <- zipWithM_ (subType l err g) (toList ts2) ts3
        Just           <$> envAddFresh l (ot', WriteLocal, Initialized) g
  where
    bSyms bs             = b_sym <$> toList bs
    toList (FI x xs)     = maybeToList x ++ xs
    err                  = errorLiquid' l

    idxMapFI f i (FI Nothing ts)  = FI     Nothing        <$> mapM (uncurry f) (zip [i..] ts)
    idxMapFI f i (FI (Just t) ts) = FI <$> Just <$> f i t <*> mapM (uncurry f) (zip [(i+1)..] ts)



-- Special casing conditional expression call here because we'd like the
-- arguments to be typechecked under a different guard each.
consCallCondExpr g l fn ets ft0
  = mseq (consCondExprArgs (srcPos l) g ets) $ \(xes, g') -> do
      ts <- T.mapM (`safeEnvFindTy` g') xes
      case [ lt | Overload cx t <- ann_fact l
                , cge_ctx g == cx
                , lt <- callSigs
                , toType t == toType lt ] of
        [ft] -> consInstantiate l g' fn ft ts xes
        _    -> cgError $ errorNoMatchCallee (srcPos l) fn (toType <$> ts) (toType <$> callSigs)
  where
    callSigs    = extractCall g ft0

----------------------------------------------------------------------------------
instantiateTy :: AnnTypeR -> CGEnv -> Int -> RefType -> CGM RefType
----------------------------------------------------------------------------------
instantiateTy l g i t = freshTyInst l g αs ts t'
    where
      (αs, t')        = bkAll t
      ts              = envGetContextTypArgs i g l αs

---------------------------------------------------------------------------------
instantiateFTy :: (PP a, PPRS F.Reft)
               => AnnTypeR -> CGEnv -> a -> RefType
               -> CGM  ([TVar], FuncInputs (Bind F.Reft), RefType)
---------------------------------------------------------------------------------
instantiateFTy l g fn ft
  = do  t'   <- freshTyInst l g αs ts t
        maybe err return $ bkFunBinds t'
    where
      (αs, t) = bkAll ft
      ts      = envGetContextTypArgs 0 g l αs
      err     = cgError $ errorNonFunction (srcPos l) fn ft

-----------------------------------------------------------------------------------
consScan :: (CGEnv -> a -> b -> CGM (Maybe (c, CGEnv))) -> CGEnv -> FuncInputs (a,b)
         -> CGM (Maybe (FuncInputs c, CGEnv))
-----------------------------------------------------------------------------------
consScan f g (FI (Just x) xs)
  = do  z  <- (uncurry $ f g) x
        case z of
          Just (x', g') ->
              do zs  <- fmap (mapFst reverse) <$> consFold step ([], g') xs
                 case zs of
                   Just (xs', g'') -> return $ Just (FI (Just x') xs', g'')
                   _               -> return $ Nothing
          _ -> return Nothing
  where
    step (ys, g) (x,y) = fmap (mapFst (:ys))   <$> f g x y

consScan f g (FI Nothing xs)
  = do  z <- fmap (mapFst reverse) <$> consFold step ([], g) xs
        case z of
          Just (xs', g') -> return $ Just (FI Nothing xs', g')
          _              -> return $ Nothing
  where
    step (ys, g) (x,y) = fmap (mapFst (:ys))   <$> f g x y


---------------------------------------------------------------------------------
consCondExprArgs :: SrcSpan
                 -> CGEnv
                 -> FuncInputs (Expression AnnTypeR, Maybe RefType)
                 -> CGM (Maybe (FuncInputs (Id AnnTypeR), CGEnv))
---------------------------------------------------------------------------------
consCondExprArgs l g (FI Nothing [(c,tc),(t,tt),(x,tx),(y,ty)])
  = mseq (consExpr g c tc) $ \(c_,gc) ->
      mseq (consExpr gc t tt) $ \(t_,gt) ->
        withGuard gt c_ True x tx >>= \case
          Just (x_, gx) ->
              withGuard gx c_ False y ty >>= \case
                Just (y_, gy) -> return $ Just (FI Nothing [c_,t_,x_,y_], gy)
                Nothing ->
                    do ttx       <- safeEnvFindTy x_ gx
                       let tty    = fromMaybe ttx ty    -- Dummy type if ty is Nothing
                       (y_, gy') <- envAddFresh l (tty, WriteLocal, Initialized) gx
                       return    $ Just (FI Nothing [c_,t_,x_,y_], gy')
          Nothing ->
              withGuard gt c_ False y ty >>= \case
                Just (y_, gy) ->
                    do tty       <- safeEnvFindTy y_ gy
                       let ttx    = fromMaybe tty tx    -- Dummy type if tx is Nothing
                       (x_, gx') <- envAddFresh l (ttx, WriteLocal, Initialized) gy
                       return     $ Just (FI Nothing [c_,t_,x_,y_], gx')
                Nothing       -> return $ Nothing
  where
    withGuard g cond b x tx =
      fmap (mapSnd envPopGuard) <$> consExpr (envAddGuard cond b g) x tx

consCondExprArgs l _ _ = cgError $ impossible l "consCondExprArgs"


---------------------------------------------------------------------------------
consFold :: (t -> b -> CGM (Maybe t)) -> t -> [b] -> CGM (Maybe t)
---------------------------------------------------------------------------------
consFold f          = foldM step . Just
  where
    step Nothing _  = return Nothing
    step (Just g) x = f g x


---------------------------------------------------------------------------------
consWhile :: CGEnv -> AnnTypeR -> Expression AnnTypeR -> Statement AnnTypeR -> CGM (Maybe CGEnv)
---------------------------------------------------------------------------------

{- Typing Rule for `while (cond) {body}`

      (a) xtIs         <- fresh G [ G(x) | x <- Φ]
      (b) GI            = G, xtIs
      (c) G            |- G(x)  <: GI(x)  , ∀x∈Φ      [base]
      (d) GI           |- cond : (xc, GI')
      (e) GI', xc:true |- body : GI''
      (f) GI''         |- GI''(x') <: GI(x)[Φ'/Φ]     [step]
      ---------------------------------------------------------
          G            |- while[Φ] (cond) body :: GI', xc:false

   The above rule assumes that phi-assignments have already been inserted. That is,

      i = 0;
      while (i < n){
        i = i + 1;
      }

   Has been SSA-transformed to

      i_0 = 0;
      i_2 = i_0;
      while [i_2] (i_2 < n) {
        i_1  = i_2 + 1;
        i_2' = i_1;
      }

-}
consWhile g l cond body
-- XXX: The RHS ty comes from PhiVarTy
  = do  (gI,tIs)            <- freshTyPhis l g xs ts                            -- (a) (b)
        _                   <- consWhileBase l xs tIs g                         -- (c)
        mseq (consExpr gI cond Nothing) $ \(xc, gI') ->                         -- (d)
          do  z             <- consStmt (envAddGuard xc True gI') body          -- (e)
              whenJustM z    $ consWhileStep l xs tIs                           -- (f)
              return         $ Just $ envAddGuard xc False gI'
    where
        (xs,ts)              = unzip $ [xts | PhiVarTy xts <- ann_fact l]

consWhileBase l xs tIs g
  = do  xts_base           <- mapM (\x -> (x,) <$> safeEnvFindTy x g) xs
        xts_base'          <- zipWithM (\(x,t) t' -> zipTypeUpM g x t t') xts_base tIs    -- (c)
        zipWithM_ (subType l err g) xts_base' tIs
  where
    err                      = errorLiquid' l

consWhileStep l xs tIs gI''
  = do  xts_step           <- mapM (\x -> (x,) <$> safeEnvFindTy x gI'') xs'
        xts_step'          <- zipWithM (\(x,t) t' -> zipTypeUpM gI'' x t t') xts_step tIs'
        zipWithM_ (subType l err gI'') xts_step' tIs'                           -- (f)
  where
    tIs'                    = F.subst su <$> tIs
    xs'                     = mkNextId   <$> xs
    su                      = F.mkSubst   $  safeZip "consWhileStep" (F.symbol <$> xs) (F.eVar <$> xs')
    err                     = errorLiquid' l

whenJustM Nothing  _ = return ()
whenJustM (Just x) f = f x

----------------------------------------------------------------------------------
envJoin :: AnnTypeR -> CGEnv -> Maybe CGEnv -> Maybe CGEnv -> CGM (Maybe CGEnv)
----------------------------------------------------------------------------------
envJoin _ _ Nothing x           = return x
envJoin _ _ x Nothing           = return x
envJoin l g (Just g1) (Just g2) = Just <$> envJoin' l g g1 g2

----------------------------------------------------------------------------------
envJoin' :: AnnTypeR -> CGEnv -> CGEnv -> CGEnv -> CGM CGEnv
----------------------------------------------------------------------------------

-- 1. use @envFindTy@ to get types for the phi-var x in environments g1 AND g2
--
-- 2. use @freshTyPhis@ to generate fresh types (and an extended environment with
--    the fresh-type bindings) for all the phi-vars using the unrefined types
--    from step 1
--
-- 3. generate subtyping constraints between the types from step 1 and the fresh
--    types
--
-- 4. return the extended environment
--
envJoin' l g g1 g2
  = do  --
        -- LOCALS: as usual
        --
        g1'       <- envAdds "envJoin-0" (zip xls l1s) g1
        g2'       <- envAdds "envJoin-1" (zip xls l2s) g2
        --
        -- t1s and t2s should have the same raw type, otherwise they wouldn't
        -- pass TC (we don't need to pad / fix them before joining).
        -- So we can use the raw type from one of the two branches and freshen
        -- up that one.
        -- FIXME: Add a raw type check on t1 and t2
        --
        (g',ls)   <- freshTyPhis' l g xls $ mapFst3 toType <$> l1s
        l1s'      <- mapM (`safeEnvFindTy` g1') xls
        l2s'      <- mapM (`safeEnvFindTy` g2') xls
        _         <- zipWithM_ (subType l err g1') l1s' ls
        _         <- zipWithM_ (subType l err g2') l2s' ls
        --
        -- GLOBALS:
        --
        let (xgs, gl1s, _) = unzip3 $ globals (zip3 xs t1s t2s)
        (g'',gls) <- freshTyPhis' l g' xgs $ mapFst3 toType <$> gl1s
        gl1s'     <- mapM (`safeEnvFindTy` g1') xgs
        gl2s'     <- mapM (`safeEnvFindTy` g2') xgs
        _         <- zipWithM_ (subType l err g1') gl1s' gls
        _         <- zipWithM_ (subType l err g2') gl2s' gls
        --
        -- PARTIALLY UNINITIALIZED
        --
        -- let (xps, ps) = unzip $ partial $ zip3 xs t1s t2s
        -- If the variable was previously uninitialized, it will continue to be
        -- so; we don't have to update the environment in this case.
        return     $ g''
    where
        (t1s, t2s) = unzip $ catMaybes $ getPhiTypes l g1 g2 <$> xs
        -- t1s : the types of the phi vars in the 1st branch
        -- t2s : the types of the phi vars in the 2nd branch
        (xls, l1s, l2s) = unzip3 $ locals (zip3 xs t1s t2s)
        xs    = [ xs | PhiVarTC xs <- ann_fact l]
        err   = errorLiquid' l


getPhiTypes _ g1 g2 x =
  case (envFindTyWithAsgn x g1, envFindTyWithAsgn x g2) of
    (Just t1, Just t2) -> Just (t1,t2)
    (_      , _      ) -> Nothing


locals  ts = [(x,s1,s2) | (x, s1@(_, WriteLocal, _), s2@(_, WriteLocal, _)) <- ts]

globals ts = [(x,s1,s2) | (x, s1@(_, WriteGlobal, Initialized), s2@(_, WriteGlobal, Initialized)) <- ts]

-- partial ts = [(x,s2)    | (x, s2@(_, WriteGlobal, Uninitialized)) <- ts]
--           ++ [(x,s1)    | (x, s1@(_, WriteGlobal, Uninitialized)) <- ts]


errorLiquid' = errorLiquid . srcPos

traceTypePP l msg act
  = do  z <- act
        case z of
          Just (x,g) -> do  t <- safeEnvFindTy x g
                            return $ Just $ trace (ppshow (srcPos l) ++ " " ++ msg ++ " : " ++ ppshow t) (x,g)
          Nothing    ->  return Nothing


-- Local Variables:
-- flycheck-disabled-checkers: (haskell-liquid)
-- End:
