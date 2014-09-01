{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE LambdaCase           #-}
{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE ConstraintKinds      #-}
{-# LANGUAGE TupleSections        #-}

-- | Top Level for Refinement Type checker
module Language.Nano.Liquid.Liquid (verifyFile) where

import           Control.Monad
import           Control.Applicative                ((<$>))

import qualified Data.HashMap.Strict                as M
import           Data.Maybe                         (listToMaybe, catMaybes)

import           Language.ECMAScript3.Syntax
import           Language.ECMAScript3.Syntax.Annotations
import           Language.ECMAScript3.PrettyPrint

import qualified Language.Fixpoint.Config           as C
import qualified Language.Fixpoint.Types            as F
import           Language.Fixpoint.Errors
import           Language.Fixpoint.Misc
import           Language.Fixpoint.Interface        (solve)

import           Language.Nano.Misc                 (mseq)
import           Language.Nano.Annots
import           Language.Nano.CmdLine              (Config,getOpts)
import           Language.Nano.Errors
import qualified Language.Nano.Env                  as E
import           Language.Nano.Locations
import           Language.Nano.Names
import           Language.Nano.Program
import           Language.Nano.Typecheck.Resolve
import           Language.Nano.Types
import           Language.Nano.Typecheck.Subst
import qualified Language.Nano.SystemUtils          as A
import           Language.Nano.Typecheck.Types
import           Language.Nano.Typecheck.Parse
import           Language.Nano.Typecheck.Typecheck  (typeCheck) 
import           Language.Nano.Typecheck.Lookup
import           Language.Nano.SSA.SSA
import           Language.Nano.Liquid.Types
import           Language.Nano.Liquid.Alias
import           Language.Nano.Liquid.CGMonad

import qualified Data.Text                          as T 

import           System.Console.CmdArgs.Default

-- import           Debug.Trace                        (trace)

type PPR r = (PP r, F.Reftable r)
type PPRS r = (PPR r, Substitutable r (Fact r)) 

--------------------------------------------------------------------------------
verifyFile    :: FilePath -> [FilePath] -> IO (A.UAnnSol RefType, F.FixResult Error)
--------------------------------------------------------------------------------
verifyFile f fs = do  (a,b) <- parse fs $ ssa $ tc $ refTc f
                      return (a,b)
parse fs next 
  = do  r <- parseNanoFromFiles fs 
        case r of 
          Left  l -> return (A.NoAnn, l) 
          Right x -> next x

ssa   next p    = ssaTransform p              >>= either (lerror . single) next
tc    next p    = typeCheck (expandAliases p) >>= either lerror next
refTc f    p    = getOpts >>= solveConstraints f . (`generateConstraints` p)

lerror          = return . (A.NoAnn,) . F.Unsafe
         
-- | solveConstraints
--   Call solve with `ueqAllSorts` enabled.
--------------------------------------------------------------------------------
solveConstraints :: FilePath -> CGInfo -> IO (A.UAnnSol RefType, F.FixResult Error) 
--------------------------------------------------------------------------------
solveConstraints f cgi 
  = do (r, s)  <- solve (C.withUEqAllSorts def True) f [] $ cgi_finfo cgi
       let r'   = fmap (ci_info . F.sinfo) r
       let ann  = cgi_annot cgi
       let sol  = applySolution s 
       return (A.SomeAnn ann sol, r') 

--------------------------------------------------------------------------------
applySolution :: F.FixSolution -> A.UAnnInfo RefType -> A.UAnnInfo RefType 
--------------------------------------------------------------------------------
applySolution = fmap . fmap . tx
  where
    tx s (F.Reft (x, zs))   = F.Reft (x, F.squishRefas (appSol s <$> zs))
    appSol _ ra@(F.RConc _) = ra 
    appSol s (F.RKvar k su) = F.RConc $ F.subst su $ M.lookupDefault F.PTop k s  

--------------------------------------------------------------------------------
generateConstraints     :: Config -> NanoRefType -> CGInfo 
--------------------------------------------------------------------------------
generateConstraints cfg pgm = getCGInfo cfg pgm $ consNano pgm

--------------------------------------------------------------------------------
consNano     :: NanoRefType -> CGM ()
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
initGlobalEnv (Nano { code = Src s }) = 
    freshenCGEnvM $ CGE nms bds grd ctx mod pth Nothing
  where
    nms       = E.envAdds (visibleNames s) E.envEmpty
    bds       = F.emptyIBindEnv
    grd       = []
    mod       = scrapeModules s 
    ctx       = emptyContext
    pth       = AP $ QPath (srcPos dummySpan) []


-------------------------------------------------------------------------------
initModuleEnv :: (F.Symbolic n, PP n) => CGEnv -> n -> [Statement AnnTypeR] -> CGM CGEnv
-------------------------------------------------------------------------------
initModuleEnv g n s = freshenCGEnvM $ CGE nms bds grd ctx mod pth (Just g)
  where

    nms       = E.envAdds (visibleNames s) E.envEmpty
    bds       = cge_fenv g
    grd       = []
    mod       = cge_mod g
    ctx       = emptyContext
    pth       = extendAbsPath (cge_path g) n


-- | `initFuncEnv l f i xs (αs, ts, t) g` 
--
--    * Pushes a new context @i@
--    * Adds return type @t@
--    * Adds binders for the type variables @αs@
--    * Adds binders for the arguments @ts@
--    * Adds binder for the 'arguments' variable
--
initFuncEnv l f i xs (αs, ts, t) g s =
    --  Compute base environment @g'@, then add extra bindings
        envAdds "initFunc-0" varBinds g'
    >>= envAdds "initFunc-1" tyBinds 
    >>= envAdds "initFunc-2" (visibleNames s)
    >>= envAdds "initFunc-3" argBind
    >>= envAddReturn f t
    >>= freshenCGEnvM
  where
    g'        = CGE nms fenv grds ctx mod pth parent
    nms       = E.envEmpty
    fenv      = cge_fenv g
    grds      = []
    mod       = cge_mod g
    ctx       = pushContext i (cge_ctx g)
    pth       = cge_path g
    parent    = Just g
    tyBinds   = [(Loc (srcPos l) α, (tVar α, ReadOnly)) | α <- αs]
    varBinds  = zip (fmap ann <$> xs) (zip ts (repeat WriteLocal))
    argBind   = [(argId l, (argTy l ts (cge_names g), ReadOnly))]
    



-------------------------------------------------------------------------------
-- | Environment wrappers
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
consEnvFindTypeDefM :: IsLocated a => a -> CGEnv -> RelName -> CGM (IfaceDef F.Reft)
-------------------------------------------------------------------------------
consEnvFindTypeDefM l γ x
  = case resolveRelNameInEnv γ x of 
      Just t  -> return t
      Nothing -> cgError $ bugClassDefNotFound (srcPos l) x


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

consMeth1 l g f xs body (i, _, ft) = consFun1 l g f xs body (i,ft)

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
  = consAsgn g l (Id lx x) e

-- e1.f = e2
consStmt g (ExprStmt l (AssignExpr _ OpAssign (LDot _ e1 f) e2))
  = do opTy   <- setPropTy l (F.symbol f) <$> safeEnvFindTy (builtinOpId BISetProp) g
       fmap snd <$> consCall g l BISetProp [e1,e2] opTy
   
-- e
consStmt g (ExprStmt _ e) 
  = fmap snd <$> consExpr g e

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
  mseq (safeEnvFindTy (builtinOpId BITruthy) g >>= consCall g l "truthy" [e]) $ \(xe,ge) -> do
    g1'      <- (`consStmt` s1) $ envAddGuard xe True  ge 
    g2'      <- (`consStmt` s2) $ envAddGuard xe False ge 
    envJoin l g g1' g2'

-- while e { s }  
consStmt g (WhileStmt l e s) 
  = Just <$> consWhile g l e s 

-- var x1 [ = e1 ]; ... ; var xn [= en];
consStmt g (VarDeclStmt _ ds)
  = consFold consVarDecl g ds
    
-- return 
consStmt g (ReturnStmt l Nothing)
  = do _ <- subType l (errorLiquid' l) g tVoid (envFindReturn g) 
       return Nothing
       
-- return e 
consStmt g (ReturnStmt l (Just e))
  = do  _ <- consCall g l "return" [e] $ returnTy (envFindReturn g) True 
        return Nothing

-- throw e 
consStmt g (ThrowStmt _ e)
  = consExpr g e >> return Nothing

-- function f(x1...xn);
consStmt g (FunctionDecl l n _ )
  = case envFindTy n g of
      Just _  -> return $ Just g
      Nothing -> cgError $ bugEnvFindTy (srcPos l) n

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
        -- FIXME: Should this check be done at TC too?
        g'       <- envAdds "consStmt-class-0" [(Loc (ann l) α, (tVar α, WriteGlobal)) | α <- t_args dfn] g
        g''      <- envAdds "consStmt-class-1" [(Loc (ann l) "this", (mkThis $ t_args dfn, WriteGlobal))] g'
        consClassElts g'' x ce
        return    $ Just g
  where
    tVars   αs    = [ tVar   α | α <- αs ] 
    rn            = RN $ QName (srcPos l) [] (F.symbol x)
    mkThis αs     = TApp (TRef rn) (tVars αs) fTop

consStmt g (IfaceStmt _)
  = return $ Just g

consStmt g (ModuleStmt _ n body)
  = initModuleEnv g n body >>= (`consStmts` body) >> return (Just g)

-- OTHER (Not handled)
consStmt _ s 
  = errorstar $ "consStmt: not handled " ++ ppshow s


-- | /*@ x :: t */
-- | var x = e;
--    
--    G     |- e :: G', xe
--    te    =  G'(xe)
--    ft    <- fresh G' t
--    G'    |- te <: ft
--    G'    |- ft <: t
--    -------------------------
--    G     |- var x /*@ t */ = e ::  G'
--    
------------------------------------------------------------------------------------
consVarDecl :: CGEnv -> VarDecl AnnTypeR -> CGM (Maybe CGEnv) 
------------------------------------------------------------------------------------
consVarDecl g v@(VarDecl l x (Just e)) =
  case listToMaybe $ scrapeVarDecl v of 
    Just ta -> mseq (consExpr g e) $ \(y, gy) -> do
                 t       <- safeEnvFindTy y gy
                 fta     <- freshTyVar gy l ta
                 _       <- subType l (errorLiquid' l) gy t fta
                 _       <- subType l (errorLiquid' l) gy fta ta
                 Just <$> envAdds "consVarDecl" [(x, (fta, WriteGlobal))] g
    _       -> consAsgn g l x e
 
consVarDecl g v@(VarDecl l x Nothing) =
  case listToMaybe $ scrapeVarDecl v of 
    Just ta -> Just <$> envAdds "consVarDecl" [(x, (ta, WriteGlobal))] g
    _       -> cgError $ errorVarDeclAnnot (srcPos l) x


-- FIXME: Do the safeExtends check here. Also add casts in the TC phase wherever
-- needed
------------------------------------------------------------------------------------
consClassElts :: PP a => CGEnv -> a -> [ClassElt AnnTypeR] -> CGM ()
------------------------------------------------------------------------------------
consClassElts g x ce 
   = mapM_ (consClassElt g x) ce


------------------------------------------------------------------------------------
consClassElt :: PP a => CGEnv -> a -> ClassElt AnnTypeR -> CGM ()
------------------------------------------------------------------------------------
consClassElt g _ (Constructor l xs body) 
  = case [ c | ConsAnn c  <- ann_fact l ] of
      [ConsSig ft]        -> do t <-    cgFunTys l i xs ft
                                mapM_ (consFun1 l g i xs body) t
      _                   -> cgError $ unsupportedNonSingleConsTy $ srcPos l
  where 
    i = Id l "constructor"

consClassElt g cid (MemberVarDecl _ static (VarDecl l1 x eo))
  = case anns of 
      []  ->  cgError       $ errorClassEltAnnot (srcPos l1) cid x
      fs  ->  case eo of
                Just e     -> void <$> consCall g l1 "field init" [e] $ ft fs
                Nothing    -> return ()
  where
    anns | static    = [ s | StatAnn  s <- ann_fact l1 ]
         | otherwise = [ f | FieldAnn f <- ann_fact l1 ]
    ft flds = mkAnd $ catMaybes $ mkInitFldTy <$> flds
  
consClassElt g cid (MemberMethDecl l static i xs body) 
  = case anns of
      [mt]  -> do mts   <- cgMethTys l i mt
                  mapM_    (consMeth1 l g i xs body) mts
      _    -> cgError  $ errorClassEltAnnot (srcPos l) cid i
  where
    anns | static    = [ (m, t) | StatAnn (StatSig _ m t)  <- ann_fact l ]
         | otherwise = [ (m, t) | MethAnn (MethSig _ m t)  <- ann_fact l ]


------------------------------------------------------------------------------------
consExprT :: CGEnv -> Expression AnnTypeR -> Maybe RefType -> CGM (Maybe (Id AnnTypeR, CGEnv)) 
------------------------------------------------------------------------------------
consExprT g e to 
  = mseq (consExpr g e) $ \(x, g') -> do
      te      <- safeEnvFindTy x g'
      case to of
        Nothing -> return $ Just (x, g')
        Just t  -> do _ <- subType l (errorLiquid' l) g' te t
                      return $ Just (x, g')
    where
       l = getAnnotation e


--------------------------------------------------------------------------------
consAsgn :: CGEnv -> AnnTypeR -> Id AnnTypeR -> Expression AnnTypeR -> CGM (Maybe CGEnv)
--------------------------------------------------------------------------------
consAsgn g _ x e =
  case envFindTyWithAsgn x g of 
    Just (t,WriteGlobal) -> mseq (consExprT g e $ Just t) $ \(_, g') -> 
                              return    $ Just g'
    Just (t,a)           -> mseq (consExprT g e $ Just t) $ \(x', g') -> do
                              t        <- safeEnvFindTy x' g'
                              Just    <$> envAdds "consAsgn-1" [(x,(t,a))] g'
    Nothing              -> mseq (consExprT g e Nothing) $ \(x', g') -> do
                              t        <- safeEnvFindTy x' g'
                              Just    <$> envAdds "consAsgn-1" [(x,(t,WriteLocal))] g'


-- | @consExpr g e@ returns a pair (g', x') where x' is a fresh, 
-- temporary (A-Normalized) variable holding the value of `e`,
-- g' is g extended with a binding for x' (and other temps required for `e`)
------------------------------------------------------------------------------------
consExpr :: CGEnv -> Expression AnnTypeR -> CGM (Maybe (Id AnnTypeR, CGEnv))
------------------------------------------------------------------------------------
consExpr g (Cast a e)
  = consCast g a e

consExpr g (IntLit l i)               
  = Just <$> envAddFresh l (eSingleton tInt i, WriteLocal) g

consExpr g (BoolLit l b)
  = Just <$> envAddFresh l (pSingleton tBool b, WriteLocal) g 

consExpr g (StringLit l s)
  = Just <$> envAddFresh l (eSingleton tString (T.pack s), WriteLocal) g

consExpr g (NullLit l)
  = Just <$> envAddFresh l (tNull, WriteLocal) g

consExpr g (ThisRef l)
  = case envFindTy (Id (ann l) "this") g of
      Just t  -> Just <$> envAddFresh l (t, WriteGlobal) g
      Nothing -> cgError $ errorUnboundId (ann l) "this" 

consExpr g (VarRef l x)
  = case envFindTy x g of
      Just t  -> addAnnot (srcPos l) x t >> return (Just (x, g))
      Nothing -> cgError $ errorUnboundId (ann l) x

consExpr g (PrefixExpr l o e)
  = do opTy         <- safeEnvFindTy (prefixOpId o) g
       consCall g l o [e] opTy

consExpr g (InfixExpr l o@OpInstanceof e1 e2)
  = mseq (consExpr g e2) $ \(x, g') -> do
       t            <- safeEnvFindTy x g'
       case t of
         TClass x   -> do opTy <- safeEnvFindTy (infixOpId o) g
                          consCall g l o [e1, StringLit l2 (cc x)] opTy
         _          -> cgError $ unimplemented (srcPos l) "tcCall-instanceof" $ ppshow e2
  where
    l2 = getAnnotation e2
    cc (RN (QName _ _ s)) = F.symbolString s 

consExpr g (InfixExpr l o e1 e2)
  = do opTy <- safeEnvFindTy (infixOpId o) g
       consCall g l o [e1, e2] opTy

-- | e ? e1 : e2
consExpr g (CondExpr l e e1 e2)
  = do opTy     <- safeEnvFindTy (builtinOpId BICondExpr) g
       consCall g l BICondExpr [e,e1,e2] opTy

-- | super(e1,..,en)
consExpr g (CallExpr l (SuperRef _) es) 
  = case envFindTy (F.symbol "this") g of
      Just t -> case extractParent g t of 
                  Just (TApp (TRef x) _ _) -> case extractCtor g (TClass x) of
                                                Just ct -> consCall g l "super" es ct
                                                _       -> cgError $ errorUnboundId (ann l) "super"
                  Just _  -> cgError $ errorUnboundId (ann l) "super"
                  Nothing -> cgError $ errorUnboundId (ann l) "super"
      Nothing -> cgError $ errorUnboundId (ann l) "this"

--   = case envFindTy (Id (ann l) "this") g of
--       Just t  ->  do  elts <- t_elts <$> getSuperDefM l t
--                       case [ t | ConsSig t <- elts ] of
--                         [ct] -> consCall g l e es ct
--                         _    -> cgError $ unsupportedNonSingleConsTy $ srcPos l
--       Nothing ->  cgError $ errorUnboundId (srcPos l) "this"

-- | e.m(es)
consExpr g (CallExpr l em@(DotRef _ e f) es)
  = mseq (consExpr g e) $ \(x,g') -> do 
      t      <- safeEnvFindTy x g'
      case t of 
        TModule r -> case resolveRelPathInEnv g r of
                       Just m  -> case E.envFindTy f $ m_variables m of
                                    Just ft -> consCall  g l em es $ thd3 ft
                                    Nothing -> cgError $ errorModuleExport (srcPos l) r f 
                       Nothing -> cgError $ bugMissingModule (srcPos l) r 
        _ -> consCallDotRef g' l em (vr x) (getElt g f t) es
  where
    -- Add a VarRef so that e is not typechecked again
    vr          = VarRef $ getAnnotation e

-- | e(es)
consExpr g (CallExpr l e es)
  = mseq (consExpr g e) $ \(x, g') -> 
      safeEnvFindTy x g' >>= consCall g' l e es

-- | e.f
consExpr g ef@(DotRef l e f)
  = mseq (consExpr g e) $ \(x,g') -> do
      te     <- safeEnvFindTy x g'
      case getProp g' (F.symbol f) te of
        Just (_, t) -> consCall g' l ef [vr x] $ mkTy te t
        Nothing     -> cgError $ errorMissingFld (srcPos l) f te
  where
    mkTy s t = mkFun ([], [B (F.symbol "this") s], t) 
    vr       = VarRef $ getAnnotation e

-- FIXME: e["f"]

-- | e1[e2]
consExpr g (BracketRef l e1 e2) 
  = do  opTy <- safeEnvFindTy (builtinOpId BIBracketRef) g
        consCall g l BIBracketRef [e1, e2] opTy

-- | e1[e2] = e3
consExpr g (AssignExpr l OpAssign (LBracket _ e1 e2) e3)
  = do  opTy <- safeEnvFindTy (builtinOpId BIBracketAssign) g
        consCall g l BIBracketAssign [e1,e2,e3] opTy

-- | [e1,...,en]
consExpr g (ArrayLit l es)
  = do  opTy <- arrayLitTy l (length es) <$> safeEnvFindTy (builtinOpId BIArrayLit) g
        consCall g l BIArrayLit es opTy

-- | {f1:e1,...,fn:en}
consExpr g (ObjectLit l bs) 
  = consCall g l "ObjectLit" es $ objLitTy l ps
  where
    (ps, es) = unzip bs

-- | new C(e, ...)
consExpr g (NewExpr l e es)
  = mseq (consExpr g e) $ \(x,g') -> do
      t       <- safeEnvFindTy x g'
      case extractCtor g t of
        Just ct -> consCall g l "constructor" es ct
        Nothing -> cgError $ errorConstrMissing (srcPos l) t 

-- | super
consExpr g (SuperRef l) 
  = case envFindTy (Id (ann l) "this") g of 
      Just t   -> case extractParent g t of 
                    Just tp -> Just <$> envAddFresh l (tp, WriteGlobal) g
                    Nothing -> cgError $ errorSuper (ann l)
      Nothing  -> cgError $ errorSuper (ann l)

-- | function(xs) { }
consExpr g (FuncExpr l fo xs body) 
  = case anns of 
      [ft]  -> do kft       <-  freshTyFun g l ft
                  fts       <-  cgFunTys l f xs kft
                  forM_ fts  $  consFun1 l g f xs body
                  Just      <$> envAddFresh l (kft, WriteGlobal) g 
      _    -> cgError        $  errorNonSingleFuncAnn $ srcPos l
  where
    anns                     = [ t | FuncAnn t <- ann_fact l ]
    f                        = maybe (F.symbol "<anonymous>") F.symbol fo


-- not handled
consExpr _ e = cgError $ unimplemented l "consExpr" e where l = srcPos  e


--------------------------------------------------------------------------------
consCast :: CGEnv -> AnnTypeR -> Expression AnnTypeR -> CGM (Maybe (Id AnnTypeR, CGEnv))
--------------------------------------------------------------------------------
consCast g a e  
  | CDead e t <- eCast = consDeadCode g l e t 
  | otherwise          = mseq (consExpr g e) $ \(x,g) -> do 
                           case eCast of
                             CNo       -> return $ Just (x,g)
                             CUp t t'  -> Just <$> consUpCast g l x t t'
                             CDn t t'  -> Just <$> consDownCast g l x t t'
                             _         -> error "impossible"
  where  
    l                  = srcPos a
    eCast              = envGetContextCast g a 
                       
-- | Dead code 
consDeadCode g l e t
  = do subType l e g t tBot
       return Nothing
    where
       tBot = strengthen t $ F.bot $ rTypeR t

-- | UpCast(x, t1 => t2)
consUpCast g l x _ t2
  = do  (tx,a)  <- safeEnvFindTyWithAsgn x g
        ztx     <- zipTypeM l g tx t2
        envAddFresh l (ztx `eSingleton` x,a) g

-- | DownCast(x, t1 => t2)
consDownCast g l x _ t2
  = do  (tx,a)  <- safeEnvFindTyWithAsgn x g
        txx     <- zipTypeM l g tx tx 
        tx2     <- zipTypeM l g t2 tx
        ztx     <- zipTypeM l g tx t2
        subType l (errorDownCast l txx t2) g txx tx2
        envAddFresh l (ztx,a) g


--------------------------------------------------------------------------------
consCall :: (PP a) => 
  CGEnv -> AnnTypeR -> a -> [Expression AnnTypeR] -> RefType -> CGM (Maybe (Id AnnTypeR, CGEnv))
--------------------------------------------------------------------------------

--   1. Fill in @instantiate@ to get a monomorphic instance of @ft@ 
--      i.e. the callee's RefType, at this call-site (You may want 
--      to use @freshTyInst@)
--   2. Use @consExpr@ to determine types for arguments @es@
--   3. Use @subType@ to add constraints between the types from (step 2) and (step 1)
--   4. Use the @F.subst@ returned in 3. to substitute formals with actuals in output type of callee.

consCall g l fn es ft0 
  = mseq (consScan consExpr g es) $ \(xes, g') -> do
     ts <- mapM (`safeEnvFindTy` g') xes
     case overload l of
         Just ft    -> do  (_,its,ot)   <- instantiate l g fn ft
                           let (su, ts') = renameBinds its xes
                           zipWithM_ (subType l err g') ts ts'
                           Just <$> envAddFresh l (F.subst su ot, WriteLocal) g'
         Nothing    -> cgError $ errorNoMatchCallee (srcPos l) fn (toType <$> ts) (toType <$> callSigs)
    where
       err           = errorLiquid' l
       overload l    = listToMaybe [ lt | Overload cx t <- ann_fact l 
                                        , cge_ctx g == cx
                                        , lt <- callSigs
                                        , toType t == toType lt ]
       callSigs      = extractCall g ft0


consCallDotRef g l fn rcvr elts es 
    -- Static call
    | all isStaticSig elts
    = consCall g l fn es $ ft isStaticSig

    -- Virtual method call
    | all isMethodSig elts 
    = consCall g l fn (rcvr:es) $ ft isMethodSig

    -- Normal function call
    | all isFieldSig elts 
    = consCall g l fn es $ ft isFieldSig

    | otherwise
    = cgError $ unsupportedDotRef (srcPos l) fn

  where
    ft f = mkAnd $ catMaybes $ mkEltFunTy <$> filter f elts


---------------------------------------------------------------------------------
instantiate :: (PP a, PPRS F.Reft) => 
  AnnTypeR -> CGEnv -> a -> RefType -> CGM  ([TVar], [Bind F.Reft], RefType)
---------------------------------------------------------------------------------
instantiate l g fn ft 
  = do  t'   <- freshTyInst l g αs ts t
        maybe err return $ bkFun t' 
    where 
      (αs, t) = bkAll ft
      ts      = envGetContextTypArgs g l αs
      err     = cgError $ errorNonFunction (srcPos l) fn ft  


-----------------------------------------------------------------------------------
consScan :: (CGEnv -> a -> CGM (Maybe (b, CGEnv))) -> CGEnv -> [a] -> CGM (Maybe ([b], CGEnv))
-- ---------------------------------------------------------------------------------
consScan f g xs    = fmap (mapFst reverse) <$> consFold step ([], g) xs
  where
    step (ys, g) x = fmap (mapFst (:ys))   <$> f g x
    

---------------------------------------------------------------------------------
-- consFold  :: (CGEnv -> b -> CGM (Maybe CGEnv)) -> CGEnv -> [b] -> CGM (Maybe CGEnv) 
consFold :: (a -> b -> CGM (Maybe a)) -> a -> [b] -> CGM (Maybe a) 
---------------------------------------------------------------------------------
consFold f          = foldM step . Just 
  where 
    step Nothing _  = return Nothing
    step (Just g) x = f g x


---------------------------------------------------------------------------------
consWhile :: CGEnv -> AnnTypeR -> Expression AnnTypeR -> Statement AnnTypeR -> CGM CGEnv
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
  = do  ts                  <- mapM (`safeEnvFindTy` g) xs 
        (gI,tIs)            <- freshTyPhis (srcPos l) g xs $ toType <$> ts  -- (a) (b) 
        _                   <- consWhileBase l xs tIs g                     -- (c)
        Just (xc, gI')      <- consExpr gI cond                             -- (d)
        z                   <- consStmt (envAddGuard xc True gI') body      -- (e)
        whenJustM z          $ consWhileStep l xs tIs                       -- (f) 
        return               $ envAddGuard xc False gI'
    where
        xs                   = concat [xs | PhiVar xs <- ann_fact l]

consWhileBase l xs tIs g    
  = do  xts_base           <- mapM (`safeEnvFindTy` g) xs 
        zipWithM_ (subType l err g) xts_base tIs                            -- (c)
  where 
   err                      = errorLiquid' l

consWhileStep l xs tIs gI'' 
  = do  xts_step           <- mapM (`safeEnvFindTy` gI'') xs' 
        zipWithM_ (subType l err gI'') xts_step tIs'                        -- (f)
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
-- 2. use @freshTyPhis@ to generate fresh types (and an extended environment with 
--    the fresh-type bindings) for all the phi-vars using the unrefined types 
--    from step 1.
-- 3. generate subtyping constraints between the types from step 1 and the fresh types
-- 4. return the extended environment.

envJoin' l g g1 g2
  = do  t1s     <- mapM (`safeEnvFindTyWithAsgn` g1) xs 
        t2s     <- mapM (`safeEnvFindTyWithAsgn` g2) xs
        g1'     <- envAdds "envJoin-0" (zip xs t1s) g1 
        g2'     <- envAdds "envJoin-1" (zip xs t2s) g2
        -- t1s and t2s should have the same raw type, otherwise they wouldn't
        -- pass TC (we don't need to pad / fix them before joining).
        -- So we can use the raw type from one of the two branches and freshen
        -- up that one.
        -- FIXME: Add a raw type check on t1 and t2
        (g',ts) <- freshTyPhis (srcPos l) g xs $ toType . fst <$> t1s
        t1s'    <- mapM (`safeEnvFindTy` g1') xs
        t2s'    <- mapM (`safeEnvFindTy` g2') xs
        _       <- zipWithM_ (subType l err g1') t1s' ts 
        _       <- zipWithM_ (subType l err g2') t2s' ts      
        return   $ g'
    where
        xs   = concat [xs | PhiVar xs <- ann_fact l] 
        err  = errorLiquid' l 


errorLiquid' = errorLiquid . srcPos

-- Local Variables:
-- flycheck-disabled-checkers: (haskell-liquid)
-- End:
