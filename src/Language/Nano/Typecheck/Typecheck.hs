{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE UndecidableInstances   #-}
{-# LANGUAGE DeriveDataTypeable     #-}
{-# LANGUAGE LambdaCase             #-}
{-# LANGUAGE ScopedTypeVariables    #-}
{-# LANGUAGE RankNTypes             #-}
{-# LANGUAGE TupleSections          #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE ConstraintKinds        #-}
{-# LANGUAGE MultiParamTypeClasses  #-}

module Language.Nano.Typecheck.Typecheck (verifyFile, typeCheck) where 

import           Control.Applicative                ((<$>), (<*>))
import           Control.Monad                
import           Control.Exception                  (throw)
import           Control.Arrow                      ((***))

import qualified Data.IntMap.Strict                 as I
import qualified Data.Map.Strict                    as M
import           Data.Maybe                         (catMaybes, listToMaybe, maybeToList, fromMaybe)
import           Data.List                          (nub)
import           Data.Monoid                        (mappend)
import           Data.Generics                   
import qualified Data.Traversable                   as T

import           Language.Nano.Annots
import           Language.Nano.CmdLine              (noFailCasts, Config)
import           Language.Nano.Errors
import           Language.Nano.Locations
import           Language.Nano.Names
import           Language.Nano.Program
import           Language.Nano.Types
import           Language.Nano.Env
import           Language.Nano.Misc                 (convertError, zipWith3M, withSingleton, withSingleton', dup)
import           Language.Nano.SystemUtils
import           Language.Nano.Typecheck.Unify
import           Language.Nano.Typecheck.Environment
import           Language.Nano.Typecheck.Types
import           Language.Nano.Typecheck.Resolve
import           Language.Nano.Typecheck.Parse 
import           Language.Nano.Typecheck.TCMonad
import           Language.Nano.Typecheck.Subst
import           Language.Nano.Typecheck.Lookup
import           Language.Nano.Liquid.Alias
import           Language.Nano.SSA.SSA

import           Language.Fixpoint.Errors
import qualified Language.Fixpoint.Types            as F
import           Language.Fixpoint.Misc             as FM 
import           Language.ECMAScript3.Syntax
import           Language.ECMAScript3.PrettyPrint
import           Language.ECMAScript3.Syntax.Annotations

-- import           Debug.Trace                        hiding (traceShow)

import qualified System.Console.CmdArgs.Verbosity as V


type PPRSF r = (PPR r, Substitutable r (Fact r), Free (Fact r)) 

--------------------------------------------------------------------------------
-- | Top-level Verifier 

--------------------------------------------------------------------------------
verifyFile :: Config -> [FilePath] -> IO (UAnnSol a, F.FixResult Error)
--------------------------------------------------------------------------------
verifyFile cfg fs
  = parseNanoFromFiles fs >>= \case 
      Left  l -> return (NoAnn, l)
      Right x -> ssaTransform x >>= \case
                   Left  l -> return (NoAnn, l)
                   Right y -> typeCheck cfg (expandAliases y) >>= \case
                                Left  l -> unsafe l
                                Right z -> return $ safe cfg z

unsafe errs = do putStrLn "\n\n\nErrors Found!\n\n" 
                 -- forM_ errs (putStrLn . ppshow) 
                 return $ (NoAnn, errs)

safe cfg (Nano {code = Src fs}) = (NoAnn, failCasts (noFailCasts cfg) fs)
    where
        failCasts True  _   = F.Safe
        failCasts False fs  = applyNonNull F.Safe F.Unsafe 
                            $ concatMap castErrors 
                            $ casts fs 

        casts              :: Data r => [Statement (AnnType r)] -> [AnnType r]
        casts stmts         = everything (++) ([] `mkQ` f) stmts
          where 
            f              :: Expression (AnnType r) -> [(AnnType r)]
            f (Cast_ a _)   = [a]
            f _             = [] 

-------------------------------------------------------------------------------
castErrors :: PPR r => AnnType r -> [Error] 
-------------------------------------------------------------------------------
castErrors (Ann _ l facts) = downErrors
  where 
    downErrors             = [errorDownCast l t1 t2 | TCast _ (CDn t1 t2) <- facts]


-------------------------------------------------------------------------------
typeCheck :: PPR r => Config -> NanoSSAR r -> IO (Either (F.FixResult Error) (NanoTypeR r))
-------------------------------------------------------------------------------
typeCheck cfg pgm = do 
  v <- V.getVerbosity
  let r = execute cfg v pgm $ tcNano pgm 
  return $ r


-------------------------------------------------------------------------------
-- | TypeCheck Nano Program
-------------------------------------------------------------------------------
tcNano :: PPR r => NanoSSAR r -> TCM r (NanoTypeR r)
-------------------------------------------------------------------------------
tcNano p@(Nano {code = Src fs})
  = do  _       <- checkTypes γ 
        (fs',_) <- tcStmts γ fs
        fs''    <- patch fs'
        ast_cnt <- getAstCount
        return   $ p { code   = Src fs'' 
                     , max_id = ast_cnt }
  where
    γ = initGlobalEnv p


-- | Patch annotation on the AST
--
-------------------------------------------------------------------------------
patch :: PPR r => [Statement (AnnSSA r)] -> TCM r [Statement (AnnSSA r)]
-------------------------------------------------------------------------------
patch fs = 
  do (m,θ)           <- (,) <$> getAnns <*> getSubst
     return           $ (pa m <$>) <$> apply θ <$> fs
  where
    pa m     (Ann i l fs)      = Ann i l $ nub $ fs ++ filter accepted (I.findWithDefault [] i m)
    accepted (TypInst _ _ _  ) = True
    accepted (Overload _ _   ) = True
    accepted (EltOverload _ _) = True
    accepted (PhiVarTy _     ) = True
    accepted _                 = False


-------------------------------------------------------------------------------
-- | Initialize environment
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
initGlobalEnv :: PPR r => NanoSSAR r -> TCEnv r
-------------------------------------------------------------------------------
initGlobalEnv (Nano { code = Src ss }) = TCE nms mod ctx pth Nothing
  where
    nms       = envAdds extras
              $ envMap (\(_,_,c,d,e) -> (d,c,e)) 
              $ mkVarEnv visibleNs
    visibleNs = visibleNames ss
    extras    = [(Id (srcPos dummySpan) "undefined", (TApp TUndef [] fTop, ReadOnly, Initialized))]
    mod       = scrapeModules ss 
    ctx       = emptyContext
    pth       = AP $ QPath (srcPos dummySpan) []


initFuncEnv γ f i αs thisTO xs ts t args s = TCE nms mod ctx pth parent
  where
    tyBinds   = [(tVarId α, (tVar α, ReadOnly, Initialized)) | α <- αs]
    varBinds  = zip (fmap ann <$> xs) $ (,WriteLocal, Initialized) <$> ts
    nms       = envAddReturn f (t, ReadOnly, Initialized)
              $ envAdds  (thisBind ++ tyBinds ++ varBinds ++ args) 
              $ envMap (\(_,_,c,d,e) -> (d,c,e)) 
              $ mkVarEnv $ visibleNames s
    mod       = tce_mod γ
    ctx       = pushContext i (tce_ctx γ) 
    pth       = tce_path γ
    parent    = Just γ
    thisBind  = (\t -> (Id (srcPos dummySpan) "this", (t, WriteGlobal, Initialized))) <$> maybeToList thisTO


---------------------------------------------------------------------------------------
initModuleEnv :: (PPR r, F.Symbolic n, PP n) => TCEnv r -> n -> [Statement (AnnSSA r)] -> TCEnv r
---------------------------------------------------------------------------------------
initModuleEnv γ n s = TCE nms mod ctx pth parent
  where
    nms       = envMap (\(_,_,c,d,e) -> (d,c,e)) $ mkVarEnv $ visibleNames s
    mod       = tce_mod γ
    ctx       = emptyContext
    pth       = extendAbsPath (tce_path γ) n
    parent    = Just γ


-------------------------------------------------------------------------------
-- | Environment wrappers
-------------------------------------------------------------------------------

tcEnvAdds     xs γ      = γ { tce_names = envAdds xs $ tce_names γ }

tcEnvAdd      x t γ     = γ { tce_names = envAdd x t $ tce_names γ }

tcEnvFindTy            :: (PPR r, F.Symbolic x, IsLocated x) => x -> TCEnv r -> Maybe (RType r)
tcEnvFindTy x γ         = fst3 <$> tcEnvFindTyWithAgsn x γ 

tcEnvFindTyWithAgsn    :: (PPR r, F.Symbolic x) => x -> TCEnv r -> Maybe (RType r, Assignability, Initialization)
tcEnvFindTyWithAgsn x γ = case envFindTy x $ tce_names γ of 
                            Just t -> Just $ adjustInit t
                            Nothing     -> 
                              case tce_parent γ of 
                                Just γ' -> tcEnvFindTyWithAgsn x γ'
                                Nothing -> Nothing
  where
    adjustInit s@(_, _, Initialized) = s
    adjustInit (t, a, _ ) = (orUndef t, a, Uninitialized)



-- 
-- This is a variant of the above that doesn't add the ' + undefined' for
-- non-initialized variables.
-- 
tcEnvFindTyForAsgn    :: (PPR r, F.Symbolic x) => x -> TCEnv r -> Maybe (RType r, Assignability, Initialization)
tcEnvFindTyForAsgn x γ = case envFindTy x $ tce_names γ of 
                           Just t -> Just $ t
                           Nothing     -> 
                             case tce_parent γ of 
                               Just γ' -> tcEnvFindTyWithAgsn x γ'
                               Nothing -> Nothing


safeTcEnvFindTy l γ x   = case tcEnvFindTy x γ of
                            Just t  -> return t
                            Nothing -> die $ bugEnvFindTy (srcPos l) x 

tcEnvFindReturn         = fst3 . envFindReturn . tce_names

tcEnvFindTypeDefM l γ x 
  = case resolveRelTypeInEnv γ x of 
      Just t  -> return t
      Nothing -> die $ bugClassDefNotFound (srcPos l) x


-------------------------------------------------------------------------------
-- | TypeCheck Function 
-------------------------------------------------------------------------------

-------------------------------------------------------------------------------
tcFun :: PPR r 
      => TCEnv r 
      -> Statement (AnnSSA r) 
      -> TCM r (Statement (AnnSSA r), Maybe (TCEnv r))
-------------------------------------------------------------------------------
tcFun γ (FunctionStmt l f xs body)
  = case tcEnvFindTy f γ of
      Just ft       -> do ts    <- tcFunTys l f xs ft
                          body' <- foldM (tcFun1 γ l f xs) body ts
                          return $ (FunctionStmt l f xs body', Just γ) 
      Nothing       -> die $ errorMissingSpec (srcPos l) f

tcFun _  s = die $ bug (srcPos s) $ "Calling tcFun not on FunctionStatement"

-------------------------------------------------------------------------------
tcFun1 :: (PPR r, IsLocated l, CallSite t) 
       => TCEnv r 
       -> AnnSSA r 
       -> l 
       -> [Id (AnnSSA r)] 
       -> [Statement (AnnSSA r)] 
       -> (t, ([TVar], Maybe (RType r), [RType r], RType r)) 
       -> TCM r [Statement (AnnSSA r)]
-------------------------------------------------------------------------------
tcFun1 γ l f xs body fty 
  = do  body'           <- addReturnStmt l t body
        tcFunBody γ' l body' t
  where
    γ' 					         = initFuncEnv γ f i αs s xs ts t arg body
    (i, (αs,s,ts,t))     = fty
    arg                  = [(argId $ srcPos l, (aTy, ReadOnly, Initialized))]
    aTy                  = argTy l ts $ tce_names γ


addReturnStmt l t body | isTVoid t 
                       = (body ++) . single <$> (`ReturnStmt` Nothing) 
                                            <$> freshenAnn l
                       | otherwise 
                       = return body
       


-- FIXME: Check for mutability (the second part in the triplet)
--        If this argument is "immutable" We will have to check
--        statements/expressions that operate on "this" and make
--        sure that they do not mutate it.
--
--        For the moment it just does a regular function check
--        
-- tcMeth1 γ l f xs body (i, _,ft) = tcFun1 γ l f xs body (i, ft)

tcFunBody γ l body t 
  = do  z                          <- tcStmts γ body
        case z of 
          (_, Just _) | t /= tVoid -> tcError $ errorMissingReturn (srcPos l)
          (b, _     ) | otherwise  -> return b


-- | Strings ahead: HACK Alert
tVarId (TV a l) = Id l $ "TVAR$$" ++ F.symbolString a   


---------------------------------------------------------------------------------------
tcClassElt :: PPR r 
          => TCEnv r -> IfaceDef r -> ClassElt (AnnSSA r) -> TCM r (ClassElt (AnnSSA r))
---------------------------------------------------------------------------------------
--
--  * Setting properties for 'this':
--
--    - Assignability : WriteGlobal
--    - Mutability    : Mutable
--
tcClassElt γ dfn (Constructor l xs body) 
  = case findAnnot of
      Just ft -> 
          do its         <- tcFunTys l i xs ft
             body'       <- foldM (tcFun1 γ' l i xs) body its
             return       $ Constructor l xs body'
      _       -> tcError  $ unsupportedNonSingleConsTy $ srcPos l
  where 
    findAnnot             = case [ c | ConsAnn c  <- ann_fact l ] of  
                              [ConsSig ft] -> Just $ ft
                              []           -> Just $ TFun Nothing [] tVoid fTop
                              _            -> Nothing
    i                     = Id l "constructor"
    γ'                    = tcEnvAdd (F.symbol "this") (mkThis $ t_args dfn, ThisVar, Initialized) γ
    mkThis (_:αs)         = TApp (TRef rn) (t_mutable : map tVar αs) fTop
    mkThis _              = die $ bug (srcPos l) "Typecheck.Typecheck.tcClassElt Constructor" 
    rn                    = RN $ QName (srcPos l) [] (F.symbol $ t_name dfn)

-- | Static field
--
tcClassElt γ dfn (MemberVarDecl l True x (Just e))
  = case spec of 
      Just (FieldSig _ _ t) -> 
          do (FI _ [e'],_) <- tcNormalCall γ l "field init" (FI Nothing [(e, Just t)]) 
                            $ mkInitFldTy t
             return         $ MemberVarDecl l True x $ Just e'
      _  ->  tcError        $ errorClassEltAnnot (srcPos l) (t_name dfn) x
  where
    spec    = M.lookup (F.symbol x, StaticMember) (t_elts dfn)

tcClassElt _ _ (MemberVarDecl l True x Nothing)
  = tcError $ unsupportedStaticNoInit (srcPos l) x

-- | Instance variable
--
tcClassElt _ _ m@(MemberVarDecl _ False _ Nothing) 
  = return m
tcClassElt _ _ (MemberVarDecl l False x _) 
  = die $ bugClassInstVarInit (srcPos l) x

-- | Static method
--
tcClassElt γ dfn (MemberMethDef l True x xs body) 
  = case spec of 
      Just (MethSig _ _ t) -> 
          do its      <- tcFunTys l x xs t
             body'    <- foldM (tcFun1 γ l x xs) body its
             return    $ MemberMethDef l True x xs body'
      _ -> tcError     $ errorClassEltAnnot (srcPos l) (t_name dfn) x
  where 
    spec               = M.lookup (F.symbol x, StaticMember) (t_elts dfn)

-- | Instance method
tcClassElt γ dfn (MemberMethDef l False x xs bd) 
  = case spec of 
      Just (MethSig _ m t) -> 
          do its      <- tcFunTys l x xs t
             bd'      <- foldM (tcFun1 (gg m) l x xs) bd its
             return    $ MemberMethDef l False x xs bd'
      _    -> tcError  $ errorClassEltAnnot (srcPos l) (t_name dfn) x
  where
    spec               = M.lookup (F.symbol x, InstanceMember) (t_elts dfn)
    gg m               = tcEnvAdd (F.symbol "this") (mkThis (ofType m) (t_args dfn), ThisVar, Initialized) γ
    mkThis m (_:αs)    = TApp (TRef rn) (m : map tVar αs) fTop
    mkThis _ _         = throw $ bug (srcPos l) "Typecheck.Typecheck.tcClassElt MemberMethDef" 
    rn                 = RN $ QName (srcPos l) [] (F.symbol $ t_name dfn)

tcClassElt _ _ m@(MemberMethDecl _ _ _ _ ) = return m


--------------------------------------------------------------------------------
tcSeq :: (TCEnv r -> a -> TCM r (a, TCEnvO r)) -> TCEnv r -> [a] -> TCM r ([a], TCEnvO r)
--------------------------------------------------------------------------------
tcSeq f             = go []
  where
    go acc γ []     = return (reverse acc, Just γ)
    go acc γ (x:xs) = do (y, γo) <- f γ x
                         case γo of
                           Nothing -> return (reverse acc ++ y:xs, Nothing) 
                           Just γ' -> go (y:acc) γ' xs

--------------------------------------------------------------------------------
tcStmts :: PPR r => 
  TCEnv r -> [Statement (AnnSSA r)] -> TCM r ([Statement (AnnSSA r)], TCEnvO r)
--------------------------------------------------------------------------------
tcStmts = tcSeq tcStmt 


-------------------------------------------------------------------------------
tcStmt  :: PPR r =>
  TCEnv r -> Statement (AnnSSA r) -> TCM r (Statement (AnnSSA r), TCEnvO r)
-------------------------------------------------------------------------------
-- skip
tcStmt γ s@(EmptyStmt _) 
  = return (s, Just γ)

-- declare function foo(...): T; 
-- this definitions will be hoisted
tcStmt γ s@(FuncAmbDecl _ _ _) 
  = return (s, Just γ)

tcStmt γ s@(FuncOverload _ _ _) 
  = return (s, Just γ)

-- interface Foo;
-- this definitions will be hoisted
tcStmt γ s@(IfaceStmt _) 
  = return (s, Just γ)

-- x = e
tcStmt γ (ExprStmt l1 (AssignExpr l2 OpAssign (LVar lx x) e))
  = do (e', g) <- tcAsgn l1 γ (Id lx x) e
       return   (ExprStmt l1 (AssignExpr l2 OpAssign (LVar lx x) e'), g)

-- e1.f = e2
tcStmt γ (ExprStmt l (AssignExpr l2 OpAssign (LDot l1 e1 f) e2))
  = do z               <- runFailM $ tcExpr γ e1 Nothing
       case z of 
         Right (_,te1) -> tcSetProp $ fmap snd3 $ getProp γ False f te1
         Left _        -> tcSetProp $ Nothing
  where
    tcSetProp rhsCtx = 
      do  opTy               <- setPropTy l (F.symbol f) <$> safeTcEnvFindTy l γ (builtinOpId BISetProp)
          (FI _ [e1',e2'],_) <- tcNormalCall γ l BISetProp (FI Nothing [(e1, Nothing), (e2, rhsCtx)]) opTy
          return              $ (ExprStmt l $ AssignExpr l2 OpAssign (LDot l1 e1' f) e2', Just γ)

-- e
tcStmt γ (ExprStmt l e)
  = do (e', to) <- tcExprW γ e
       return (ExprStmt l e', const γ <$> to)
           
-- s1;s2;...;sn
tcStmt γ (BlockStmt l stmts) 
  = do (stmts', g) <- tcStmts γ stmts
       return (BlockStmt l stmts', g)

-- if b { s1 }
tcStmt γ (IfSingleStmt l b s)
  = tcStmt γ (IfStmt l b s (EmptyStmt l))

-- if b { s1 } else { s2 }
tcStmt γ (IfStmt l e s1 s2)
  = do opTy         <- safeTcEnvFindTy l γ (builtinOpId BITruthy)
       ([e'], z)    <- tcNormalCallW γ l BITruthy [e] opTy
       case z of 
         Just _  -> do (s1', γ1) <- tcStmt γ s1
                       (s2', γ2) <- tcStmt γ s2
                       γ3        <- envJoin l γ γ1 γ2
                       return       (IfStmt l e' s1' s2', γ3)
         _       -> return (IfStmt l e' s1 s2, Nothing)

-- while c { b } 
tcStmt γ (WhileStmt l c b) 
  = do (c', to)  <- tcExprW γ c
       case to of
         Nothing -> return (WhileStmt l c' b, Nothing)
         Just t  -> do unifyTypeM (srcPos l) γ t tBool
                       pTys         <- mapM (safeTcEnvFindTy l γ) phis
                       (b', γl)     <- tcStmt (tcEnvAdds (zip xs ((,WriteLocal,Initialized) <$> pTys)) γ) b
                       γout         <- envLoopJoin l γ γl
                       return        $ (WhileStmt l c' b', γout)  
    where 
       xs            = [ mkNextId x | x <- phis ]
       phis          = [ x | x <- phiVarsAnnot l ]

-- var x1 [ = e1 ]; ... ; var xn [= en];
tcStmt γ (VarDeclStmt l ds)
  = do (ds', z) <- tcSeq tcVarDecl γ ds
       return      (VarDeclStmt l ds', z)

-- return e 
tcStmt γ (ReturnStmt l eo) 
  = tcRetW γ l eo

-- throw e 
tcStmt γ (ThrowStmt l e) 
  = (,Nothing) . ThrowStmt l . fst <$> tcExprW γ e


tcStmt γ s@(FunctionStmt _ _ _ _)
  = tcFun γ s

-- | class A<S...> [extends B<T...>] [implements I,J,...] { ... }
tcStmt γ (ClassStmt l x e is ce) 
  = do  dfn      <- tcEnvFindTypeDefM l γ rn
        ms       <- mapM (tcClassElt γ dfn) ce
        return    $ (ClassStmt l x e is ms, Just γ)
  where
    rn            = RN $ QName (srcPos l) [] (F.symbol x)

-- | module M { ... } 
tcStmt γ (ModuleStmt l n body) 
  = (ModuleStmt l n *** return (Just γ)) <$>  tcStmts (initModuleEnv γ n body) body

-- | enum M { ... } 
tcStmt γ (EnumStmt l n body) 
  = return (EnumStmt l n body, Just γ)

-- OTHER (Not handled)
tcStmt _ s 
  = convertError "tcStmt" s


---------------------------------------------------------------------------------------
tcVarDecl ::  PPR r => TCEnv r -> VarDecl (AnnSSA r) -> TCM r (VarDecl (AnnSSA r), TCEnvO r)
---------------------------------------------------------------------------------------
tcVarDecl γ v@(VarDecl l x (Just e))
  = case scrapeVarDecl v of
      [ ]     -> do (e', to)   <- tcExprW γ e
                    return      $ (VarDecl l x (Just e'), tcEnvAddo γ x $ (,WriteLocal,Initialized) <$> to)
      [(_,t)] -> f WriteGlobal <$> tcCast γ l e t
      _       -> tcError        $ errorVarDeclAnnot (srcPos l) x
  where
    f a = (VarDecl l x . Just *** Just . (`tcEnvAdds` γ) . single . (x,) . (,a, Initialized)) 

tcVarDecl γ v@(VarDecl l x Nothing)
  = case scrapeVarDecl v of
      [ ]                   -> tcVarDecl γ $ VarDecl l x $ Just $ VarRef l $ Id l "undefined"
      [(AmbVarDeclKind, t)] -> return      $ (v, Just $ tcEnvAdds [(x, (t,WriteGlobal, Initialized))] γ)
      [(_, t)]              -> return      $ (v, Just $ tcEnvAdds [(x, (t,WriteGlobal, Uninitialized))] γ)
      _                     -> tcError     $ errorVarDeclAnnot (srcPos l) x

-------------------------------------------------------------------------------
tcAsgn :: PPR r 
       => AnnSSA r -> TCEnv r -> Id (AnnSSA r) -> ExprSSAR r -> TCM r (ExprSSAR r, TCEnvO r)
-------------------------------------------------------------------------------
tcAsgn l γ x e
  = do (e' , to)    <- tcExprTW l γ e rhsT
       return       $ (e', tcEnvAddo γ x $ (,asgn,init) <$> to)
    where
       (rhsT, asgn, init) = case tcEnvFindTyForAsgn x γ of
                              Just (t,a,i) -> (Just t, a, Initialized)
                              Nothing      -> (Nothing, WriteLocal, Initialized)

tcEnvAddo _ _ Nothing  = Nothing
tcEnvAddo γ x (Just t) = Just $ tcEnvAdds [(x, t)] γ 

  
----------------------------------------------------------------------------------------------------------------
tcExprTW :: PPR r => AnnSSA r -> TCEnv r -> ExprSSAR r -> Maybe (RType r) -> TCM r (ExprSSAR r, Maybe (RType r))
tcExprW  :: PPR r => TCEnv r -> ExprSSAR r -> TCM r (ExprSSAR r, Maybe (RType r))
tcExprWD :: PPR r => TCEnv r -> ExprSSAR r -> Maybe (RType r) -> TCM r (ExprSSAR r, RType r)
----------------------------------------------------------------------------------------------------------------
tcExprTW _ γ e Nothing    = tcExprW γ e
tcExprTW l γ e (Just t)   = (tcWrap $ tcExprT l γ e t)    >>= tcEW γ e

tcExprW γ e               = (tcWrap $ tcExpr γ e Nothing) >>= tcEW γ e 

tcExprWD γ e t            = (tcWrap $ tcExpr γ e t)       >>= tcEW γ e >>= \case 
                              (e, Just t) -> return (e, t)
                              (e, _     ) -> return (e, tNull)

                                 

tcNormalCallW γ l o es t = (tcWrap $ tcNormalCall γ l o (FI Nothing ((,Nothing) <$> es)) t) >>= \case
                             Right (FI _ es', t') -> return (es', Just t')
                             Left err             -> (,Nothing) <$> mapM (deadcastM (tce_ctx γ) err) es

tcRetW γ l (Just e)
  = (tcWrap $ tcNormalCall γ l "return" (FI Nothing [(e, Just retTy)]) (returnTy retTy True)) >>= \case
       Right (FI _ es', _) -> (,Nothing) . ReturnStmt l . Just <$> return (head es')
       Left err            -> (,Nothing) . ReturnStmt l . Just <$> deadcastM (tce_ctx γ) err e
  where
    retTy = tcEnvFindReturn γ 

tcRetW γ l Nothing
  = do (_, _) <- tcNormalCall γ l "return" (FI Nothing []) $ returnTy (tcEnvFindReturn γ) False
       return  $ (ReturnStmt l Nothing, Nothing)
  
tcEW :: PPR r => TCEnv r -> ExprSSAR r -> Either Error ((ExprSSAR r), b) -> TCM r ((ExprSSAR r), Maybe b)
tcEW _ _ (Right (e', t')) = return $  (e', Just t')
tcEW γ e (Left err)       = (, Nothing) <$> deadcastM (tce_ctx γ) err e 

-------------------------------------------------------------------------------
tcExprT :: PPR r => AnnSSA r -> TCEnv r -> ExprSSAR r -> RType r -> TCM r (ExprSSAR r, RType r)
-------------------------------------------------------------------------------
tcExprT l γ e t 
  = do (FI _ [e'], _) <- tcNormalCall γ l "tcExprT" (FI Nothing [(e, Nothing)]) 
                       $ TFun Nothing [B (F.symbol "x") t] tVoid fTop
       return (e', t)

-------------------------------------------------------------------------------
tcExpr :: PPR r => TCEnv r -> ExprSSAR r -> Maybe (RType r) -> TCM r (ExprSSAR r, RType r)
-------------------------------------------------------------------------------
tcExpr _ e@(IntLit _ _) _
  = return (e, tInt)

tcExpr _ e@(BoolLit _ _) _
  = return (e, tBool)

tcExpr _ e@(StringLit _ _) _
  = return (e, tString)

tcExpr _ e@(NullLit _) _
  = return (e, tNull)

tcExpr γ e@(ThisRef l) _
  = case tcEnvFindTy (F.symbol "this") γ of 
      Just t  -> return (e, t) 
      Nothing -> tcError $ errorUnboundId (ann l) "this"

tcExpr γ e@(VarRef l x) _
  = case tcEnvFindTy x γ of
      Just t  -> return (e, t)
      Nothing -> tcError $ errorUnboundId (ann l) x
 
-- | e ? e1 : e2
--   
--   Conditional expresion is transformed to a call to a function with
--   signature: 
--
--     forall C . (c: C, _t: T, x: T, y: T) => T
--
--   The arguments are:
--    
--    * The condition expression
--    * A phony expression with: 
--      - The contextual type `t` if there exists one
--      - Top, otherwise
--    * The first conditional expression
--    * The second conditional expression
--
tcExpr γ (CondExpr l e e1 e2) to
  = do  opTy                      <- mkTy to <$> safeTcEnvFindTy l γ (builtinOpId BICondExpr)
        (sv,v)                    <- dup F.symbol (VarRef l) <$> freshId l
        let γ'                     = tcEnvAdd sv (tt, WriteLocal, Initialized) γ
        (FI _ [e',_,e1',e2'], t') <- tcNormalCall γ' l BICondExpr (args v) opTy
        return                     $ (CondExpr l e' e1' e2', t')
  where
    args v   = FI Nothing [(e,Nothing), (v, Nothing),(e1,to),(e2,to)]
    tt       = fromMaybe tTop to
    mkTy Nothing (TAll cv (TAll tv (TFun Nothing [B c_ tc, B t_ _, B x_ xt, B y_ yt] o r))) = 
      TAll cv (TAll tv (TFun Nothing [B c_ tc, B t_ tTop, B x_ xt, B y_ yt] o r))
    mkTy _ t = t

tcExpr γ e@(PrefixExpr _ _ _) _
  = tcCall γ e 

tcExpr γ e@(InfixExpr _ _ _ _) _
  = tcCall γ e 

-- | f(e)
tcExpr γ e@(CallExpr _ _ _) _
  = tcCall γ e 

-- | [e1,..,en]
tcExpr γ e@(ArrayLit _ _) _
  = tcCall γ e 
 
-- | { f: e }
tcExpr γ e@(ObjectLit _ _) _
  = tcCall γ e

-- | < t > e
tcExpr γ ex@(Cast l e) _
  = case [ ct | UserCast ct <- ann_fact l ] of
      [t] -> mapFst (Cast l) <$> tcCast γ l e t
      _   -> die $  bugNoCasts (srcPos l) ex

-- | Subtyping induced cast
--
--   If the existing cast has been added by another context (i.e. e' == Cast_  ...) 
--   then typecheck the contents of the cast and return the type of the internal 
--   expression.
--
--   If it's from the same context then the internal expression has been
--   typechecked, so just return the inferred type.
--
tcExpr γ (Cast_ l e) to
  = case [ t_ | TCast ξ t_ <- ann_fact l, tce_ctx γ == ξ ] of
      [ ] -> do (e', t)    <- tcExpr γ e to
                case e' of 
                  Cast_ {} -> die $ bugNestedCasts (srcPos l) e 
                  _        -> (,t) . (`Cast_` e') <$> freshenAnn l
      [c] -> return (Cast_ l e, castType c) 
      _   -> die $ bugNestedCasts (srcPos l) e
 
-- | e.f
tcExpr γ e@(DotRef _ _ _) _
  = tcCall γ e
 
-- | e1[e2]
tcExpr γ e@(BracketRef _ _ _) _
  = tcCall γ e

-- | e1[e2] = e3
tcExpr γ e@(AssignExpr _ OpAssign (LBracket _ _ _) _) _
  = tcCall γ e

-- | new C(e, ...)
tcExpr γ e@(NewExpr _ _ _) _ 
  = tcCall γ e

-- | super
tcExpr γ e@(SuperRef l) _
  = case tcEnvFindTy (F.symbol "this") γ of
      Just t   -> case extractParent γ t  of 
                    Just tp -> return (e, tp)
                    Nothing -> tcError $ errorSuper (ann l)
      Nothing  -> tcError $ errorSuper (ann l)

-- | function (x,..) {  }
tcExpr γ (FuncExpr l fo xs body) tCtxO
  = case anns of 
      [ft] -> tcFuncExpr ft
      _    -> case tCtxO of
                Just tCtx -> tcFuncExpr tCtx
                Nothing   -> tcError $ errorNoFuncAnn $ srcPos l
  where
    tcFuncExpr t = do ts    <- tcFunTys l f xs t
                      body' <- foldM (tcFun1 γ l f xs) body ts
                      return $ (FuncExpr l fo xs body', t)
    anns         = [ t | FuncAnn t <- ann_fact l ]
    f            = maybe (F.symbol "<anonymous>") F.symbol fo

tcExpr _ e _ 
  = convertError "tcExpr" e


-- | @tcCast@ emulating a simplified version of a function call
---------------------------------------------------------------------------------------
tcCast :: PPR r => TCEnv r -> AnnSSA r -> ExprSSAR r -> RType r -> TCM r (ExprSSAR r, RType r)
---------------------------------------------------------------------------------------
tcCast γ l e tc 
  = do  opTy                <- safeTcEnvFindTy l γ (builtinOpId BICastExpr)
        cid                 <- freshId l
        let γ'               = tcEnvAdd (F.symbol cid) (tc, WriteLocal, Initialized) γ
        (FI _ [_, e'], t')  <- tcNormalCall γ' l "user-cast" (FI Nothing [(VarRef l cid, Nothing),(e, Just tc)]) opTy  
        return               $ (e', t')


---------------------------------------------------------------------------------------
tcCall :: PPR r => TCEnv r -> ExprSSAR r -> TCM r (ExprSSAR r, RType r)
---------------------------------------------------------------------------------------

-- | `o e`
tcCall γ (PrefixExpr l o e)        
  = do opTy                   <- safeTcEnvFindTy l γ (prefixOpId o)
       z                      <- tcNormalCall γ l o (FI Nothing [(e, Nothing)]) opTy
       case z of
         (FI _ [e'], t)       -> return (PrefixExpr l o e', t)
         _                    -> tcError $ impossible (srcPos l) "tcCall PrefixExpr"

-- | `e1 o e2`
tcCall γ (InfixExpr l o@OpInstanceof e1 e2) 
  = do (e2',t)                <- tcExpr γ e2 Nothing
       case t of
         TClass (RN (QName _ _ x))  -> 
              do  opTy              <- safeTcEnvFindTy l γ (infixOpId o)
                  (FI _ [e1',_], t) <- 
                      let args = FI Nothing ((,Nothing) <$> [e1, StringLit l2 (F.symbolString x)]) in
                      tcNormalCall γ l o args opTy
                      -- FIXME: add qualified name
                  return (InfixExpr l o e1' e2', t) 
         _  -> tcError $ unimplemented (srcPos l) "tcCall-instanceof" $ ppshow e2
  where
    l2 = getAnnotation e2

tcCall γ (InfixExpr l o e1 e2)        
  = do opTy                   <- safeTcEnvFindTy l γ (infixOpId o)
       z                      <- tcNormalCall γ l o (FI Nothing [(e1, Nothing), (e2, Nothing)]) opTy
       case z of
         (FI _ [e1', e2'], t) -> return (InfixExpr l o e1' e2', t)
         _                    -> tcError $ impossible (srcPos l) "tcCall InfixExpr"

-- | `e1[e2]`
--
--   Special case for Enumeration. might be able to do something better with the 
--   overload for BIBracketRef
--
tcCall γ (BracketRef l e1 e2)
  = do  opTy <- runFailM (tcExpr γ e1 Nothing) >>= \case
                  Right (_, TEnum n)   -> case resolveRelEnumInEnv γ n of
                                            Just ed -> return $ ofType $ toType $ enumTy ed
                                            _       -> safeTcEnvFindTy l γ $ builtinOpId BIBracketRef
                  _ -> safeTcEnvFindTy l γ $ builtinOpId BIBracketRef
        tcNormalCall γ l BIBracketRef (FI Nothing [(e1, Nothing), (e2, Nothing)]) opTy >>= \case
          (FI _ [e1', e2'], t) -> return (BracketRef l e1' e2', t)
          _                    -> tcError $ impossible (srcPos l) "tcCall BracketRef"
   
-- | `e1[e2] = e3`
tcCall γ (AssignExpr l OpAssign (LBracket l1 e1 e2) e3)
  = do opTy                         <- safeTcEnvFindTy l γ (builtinOpId BIBracketAssign)
       z                            <- tcNormalCall γ l BIBracketAssign (FI Nothing ((,Nothing) <$> [e1,e2,e3])) opTy
       case z of
         (FI _ [e1', e2', e3'], t)  -> return (AssignExpr l OpAssign (LBracket l1 e1' e2') e3', t)
         _                          -> tcError $ impossible (srcPos l) "tcCall AssignExpr"

-- | `[e1,...,en]`
tcCall γ (ArrayLit l es)
  = do opTy                   <- arrayLitTy l (length es) <$> safeTcEnvFindTy l γ (builtinOpId BIArrayLit)
       (FI _ es', t)          <- tcNormalCall γ l BIArrayLit (FI Nothing ((,Nothing) <$> es)) opTy
       return                  $ (ArrayLit l es', t)

-- | `{ f1:t1,...,fn:tn }`
tcCall γ (ObjectLit l bs) 
  = do (FI _ es', t)          <- tcNormalCall γ l "ObjectLit" (FI Nothing ((,Nothing) <$> es)) $ objLitTy l ps 
       return                  $ (ObjectLit l (zip ps es'), t)
  where
    (ps,es) = unzip bs

-- | `new e(e1,...,en)`
tcCall γ (NewExpr l e es) 
  = do (e',t)                 <- tcExpr γ e Nothing
       case extractCtor γ t of 
         Just ct -> 
            do (FI _ es', t)  <- tcNormalCall γ l "constructor" (FI Nothing ((,Nothing) <$> es)) ct
               return          $ (NewExpr l e' es', t)
         _       -> tcError    $ errorConstrMissing (srcPos l) t

-- | e.f 
--   
--   Accessing field @f@ of an expression @e@ with type @te@, causes an implicit
--   coercion of @e@ to a type @te'@ (this type is a subtype of @te@ and
--   accounts for the case where @te@ is a union type where not all parts of the 
--   union can be accessed successfully at offset @f@. This is captured by the
--   call to `mkTy te' t`, that produces an accessor function with type:
--
--      getProp_f :: (this: te') => t
--
--   The coercion occurs when calling `getProp_f` with @e@ as argument.
--
tcCall γ ef@(DotRef l e f)
  = runFailM (tcExpr γ e Nothing) >>= \case 
      Right (_, te) -> case getProp γ False f te of
                         Just (te', t, _) ->
                           do (FI _ [e'],τ) <- tcNormalCall γ l ef (FI Nothing [(e, Nothing)]) $ mkTy te' t
                              return         $ (DotRef l e' f, τ)
                         Nothing         -> tcError $ errorMissingFld (srcPos l) f te
      Left err      -> tcError err
  where
    mkTy s t         = mkFun ([],Nothing,[B (F.symbol "this") s],t) 

         
-- | `super(e1,...,en)`
tcCall γ (CallExpr l e@(SuperRef _)  es) 
  = case tcEnvFindTy (F.symbol "this") γ of 
      Just t -> 
          case extractParent γ t of 
            Just (TApp (TRef x) _ _) -> 
                case extractCtor γ (TClass x) of
                  Just ct -> do (FI _ es',t') <- tcNormalCall γ l "constructor" (FI Nothing ((,Nothing) <$> es)) ct
                                return         $ (CallExpr l e es', t')
                  _       -> tcError $ errorUnboundId (ann l) "super"
            _ -> tcError $ errorUnboundId (ann l) "super"
      Nothing -> tcError $ errorUnboundId (ann l) "this"

-- | `e.f(es)`
--
--  FIXME: cast @e@ to the subtype for which @f@ is an existing field.
--
tcCall γ (CallExpr l em@(DotRef l1 e f) es)
  = do z              <- runFailM (tcExpr γ e Nothing)
       case z of 
         Right (_, t) | isVariadicCall f -> 
            case es of
              []   -> tcError $ errorVariadicNoArgs (srcPos l) em
              v:vs -> do  (e', _)                <- tcExpr γ e Nothing
                          (FI (Just v') vs', t') <- tcNormalCall γ l em (FI (Just (v, Nothing)) (nth vs)) t
                          return                  $ (CallExpr l (DotRef l1 e' f) (v':vs'), t')

         Right (_, t) | otherwise        -> 
            case getProp γ True f t of
              Just (_,tf,_) -> 
                  do  (FI (Just e') es', t')  <- tcNormalCall γ l em (FI (Just (e, Nothing)) (nth es)) tf
                      return                   $ (CallExpr l (DotRef l1 e' f) es', t')
              Nothing      -> tcError $ errorCallNotFound (srcPos l) e f
         Left err     -> tcError err
  where
    isVariadicCall f = F.symbol f == F.symbol "call"
    nth = ((,Nothing) <$>)

-- | `e(es)`
tcCall γ (CallExpr l e es)
  = do (e', ft0)              <- tcExpr γ e Nothing
       (FI _ es', t)          <- tcNormalCall γ l e (FI Nothing ((,Nothing) <$> es)) ft0
       return                  $ (CallExpr l e' es', t)

tcCall _ e = tcError $ unimplemented (srcPos e) "tcCall" e

------------------------------------------------------------------------------------------
-- | @tcNormalCall@ resolves overloads and returns cast-wrapped versions of the arguments.
------------------------------------------------------------------------------------------
tcNormalCall :: (PPRSF r, PP a) 
             => TCEnv r 
             -> AnnSSA r 
             -> a 
             -> FuncInputs (ExprSSAR r, Maybe (RType r)) 
             -> RType r 
             -> TCM r (FuncInputs (ExprSSAR r), RType r) 
------------------------------------------------------------------------------------------
tcNormalCall γ l fn etos ft0 
  = do ets            <- T.mapM (uncurry $ tcExprWD γ) etos
       z              <- resolveOverload γ l fn ets ft0
       case z of 
         Just (θ, ft) -> do addAnn (ann_id l) $ Overload (tce_ctx γ) ft
                            addSubst l θ
                            tcCallCase γ l fn ets ft
         Nothing      -> tcError $ uncurry (errorCallNotSup (srcPos l) fn ft0) $ toLists ets
                         -- do tcWrap $ tcError $ uncurry (errorCallNotSup (srcPos l) fn ft0) $ toLists ets
                         --    return (fst <$> ets, tNull)
  where
    toList (FI to ts)  = maybeToList to ++ ts
    toLists f          = (toList $ fst <$> f, toList $ snd <$> f)


-- | `resolveOverload γ l fn es ts ft`
--
--   When resolving an overload there are two prossible cases:
--
--   * There is only a single signature available: then return just this
--     signature regardless of subtyping constraints
--
--   * There are more than one signature available: return all that pass the
--     subtype check (this is what tcCallCaseTry does).
--
------------------------------------------------------------------------------------------
resolveOverload :: (PPR r, PP a) 
                => TCEnv r 
                -> AnnSSA r 
                -> a 
                -> FuncInputs (ExprSSAR r, RType r) 
                -> RType r 
                -> TCM r (Maybe (RSubst r, RType r)) 
------------------------------------------------------------------------------------------
-- | A function signature is compatible if:
--
--   * The supplied parameters have the same number of 'normal' arguments, i.e.
--     not including the 'self' argument.
--
--   * If the function requires a 'self' argument, the parameters provide one.
--
resolveOverload γ l fn ets ft 
  = case [ mkFun (vs,s,τs,τ) | (vs,s,τs,τ) <- sigs
                             , length τs == largs ets
                             , lMaybe s  <= lself ets ] of
      [t]    -> Just . (,t) <$> getSubst 
      fts    -> tcCallCaseTry γ l fn (snd <$> ets) fts
  where
    lself (FI (Just _) _) = 1
    lself (FI _        _) = 0
    largs (FI _ e)        = length e
    lMaybe Nothing        = (0 :: Int)
    lMaybe _              = (1 :: Int)
    sigs                  = catMaybes (bkFun <$> extractCall γ ft)


----------------------------------------------------------------------------------
-- | A successful pairing of formal to actual parameters will return `Just θ`,
--   where @θ@ is the corresponding substitution. If the types are not acceptable 
--   this will return `Nothing`. In this case successful means:
--
--    * Unifying without errors.
--
--    * Passing the subtyping test.
--
--   The monad state is completely reversed after this function returns, thanks 
--   to `runMaybeM`. We don't need to reverse the action of `instantiateFTy`.
----------------------------------------------------------------------------------
tcCallCaseTry :: (PPR r, PP a) 
              => TCEnv r 
              -> AnnSSA r 
              -> a 
              -> FuncInputs (RType r) 
              -> [RType r]
              -> TCM r (Maybe (RSubst r, RType r))
----------------------------------------------------------------------------------
tcCallCaseTry γ l fn ts [] = return Nothing
tcCallCaseTry γ l fn ts (ft:fts)
  = do  z <- runMaybeM $ 
               do  (_,its1,_)      <- instantiateFTy l (tce_ctx γ) fn ft
                   ts1             <- idxMapFI (instantiateTy l $ tce_ctx γ) ts
                   let (ts2, its2)  = balance ts1 its1
                   θ'              <- unifyTypesM (srcPos l) γ ts2 its2
                   zipWithM_          (subtypeM (srcPos l) γ) (apply θ' $ toList ts2) 
                                                              (apply θ' $ toList its2)
                   return           $ θ'
        case z of 
          Just θ  -> return $ Just (θ, ft)
          Nothing -> tcCallCaseTry γ l fn ts fts
  where
    toList (FI to ts)      = maybeToList to ++ ts

idxMapFI f (FI Nothing ts)  = FI     Nothing        <$> mapM (uncurry f) (zip [1..] ts)
idxMapFI f (FI (Just t) ts) = FI <$> Just <$> f 0 t <*> mapM (uncurry f) (zip [2..] ts)

-- `balance supplied_parameters function_sig` should preserve the structure of
-- the supplied_parameters.
balance (FI (Just to) ts) (FI Nothing fs)  = (FI (Just to) ts, FI (Just to) fs)
balance (FI Nothing ts)   (FI (Just _) fs) = (FI Nothing ts, FI Nothing fs)
balance ts                fs               = (ts, fs) 


----------------------------------------------------------------------------------
tcCallCase :: (PP a, PPRSF r) 
           => TCEnv r 
           -> AnnSSA r 
           -> a 
           -> FuncInputs (ExprSSAR r, RType r) 
           -> RType r 
           -> TCM r (FuncInputs (ExprSSAR r), RType r)
----------------------------------------------------------------------------------
tcCallCase γ l fn ets ft  
  = do let ξ            = tce_ctx γ
       (_,its1,ot)     <- instantiateFTy l ξ fn ft
       ts1             <- idxMapFI (instantiateTy l $ tce_ctx γ) ts
       let (ts2, its2)  = balance ts1 its1
       θ               <- unifyTypesM (srcPos l) γ ts2 its2
       let (ts3,its3)   = mapPair (apply θ) (ts2, its2)
       es'             <- app (castM γ) es ts3 its3
       -- es'             <- app (castM γ) es (ltracePP l "LHS" ts3) (ltracePP l "RHS" its3)
       return           $ (es', apply θ ot)
  where
    (es, ts)            = (fst <$> ets, snd <$> ets)
    app f (FI (Just a) as) (FI (Just b) bs) (FI (Just c) cs) = FI <$> (Just <$> f a b c) 
                                                                  <*> zipWith3M f as bs cs
    app f (FI _        as) (FI _        bs) (FI _        cs) = FI <$> return Nothing     
                                                                  <*> zipWith3M f as bs cs

----------------------------------------------------------------------------------
instantiateTy :: PPR r => AnnSSA r -> IContext -> Int -> RType r -> TCM r (RType r)
----------------------------------------------------------------------------------
instantiateTy l ξ i = uncurry (freshTyArgs l i ξ) . bkAll 

----------------------------------------------------------------------------------
instantiateFTy :: (PPR r, PP a) 
               => AnnSSA r 
               -> IContext 
               -> a 
               -> RType r 
               -> TCM r ([TVar], FuncInputs (RType r), RType r)
----------------------------------------------------------------------------------
instantiateFTy l ξ fn ft 
  = do t'              <- freshTyArgs l 0 ξ αs t 
       maybe err return $ bkFunNoBinds t'
    where
       (αs, t)          = bkAll ft
       err = tcError    $ errorNonFunction (srcPos l) fn ft

----------------------------------------------------------------------------------
envJoin :: PPR r => AnnSSA r -> TCEnv r -> TCEnvO r -> TCEnvO r -> TCM r (TCEnvO r)
----------------------------------------------------------------------------------
envJoin _ _ Nothing x           = return x
envJoin _ _ x Nothing           = return x
envJoin l γ (Just γ1) (Just γ2) = 
  do  tas       <- mapM (getPhiType l γ1 γ2) xs

      -- locals ts  = [(x,s1,s2) | (x, s1@(t1, WriteLocal, i1), s2@(t2, WriteLocal, i2)) <- ts]

      θ         <- getSubst
      return $ Just $ tcEnvAdds  (zip xs tas) $ γ { tce_names = apply θ (tce_names γ) }
  where
      xs = phiVarsAnnot l


----------------------------------------------------------------------------------
envLoopJoin :: PPR r => AnnSSA r -> TCEnv r -> TCEnvO r -> TCM r (TCEnvO r)
----------------------------------------------------------------------------------
envLoopJoin _ γ Nothing   = return $ Just γ
envLoopJoin l γ (Just γl) = 
  do  ts    <- mapM (getLoopNextPhiType l γ γl) xs
      γ'    <- (`substNames` γ) <$> getSubst
      return $ Just $ tcEnvAdds (zip xs ts) γ'
  where 
      xs             = phiVarsAnnot l 
      substNames θ γ = γ { tce_names = apply θ (tce_names γ) }


-- 
-- Using @tcEnvFindTyForAsgn@ here as the initialization status is 
-- recorded in the initialization part of the output.
--
----------------------------------------------------------------------------------
getPhiType :: PPR r 
           => AnnSSA r 
           -> TCEnv r 
           -> TCEnv r 
           -> Var r 
           -> TCM r (RType r, Assignability, Initialization)
----------------------------------------------------------------------------------
getPhiType l γ1 γ2 x =
  case (tcEnvFindTyForAsgn x γ1, tcEnvFindTyForAsgn x γ2) of
    (Just (t1,a1,i1), Just (t2,_,i2)) -> do θ     <- getSubst 
                                            t     <- unifyPhiTypes l γ1 x t1 t2 θ
                                            return $ (t, a1, i1 `mappend` i2)
    (_              , _             )  | forceCheck (fmap srcPos x) γ1 && forceCheck (fmap srcPos x) γ2 
                                      -> die $ bug (srcPos l) "Oh no, the HashMap GREMLIN is back..."
                                       | otherwise 
                                      -> die $ bugUnboundPhiVar (srcPos l) x

----------------------------------------------------------------------------------
getLoopNextPhiType :: PPR r 
                   => AnnSSA r 
                   -> TCEnv r 
                   -> TCEnv r 
                   -> Var r 
                   -> TCM r (RType r, Assignability, Initialization)
----------------------------------------------------------------------------------
getLoopNextPhiType l γ γl x =
  case (tcEnvFindTyForAsgn x γ, tcEnvFindTyForAsgn (mkNextId x) γl) of
    (Just (t1,a1,i1), Just (t2,_,i2)) -> do θ     <- getSubst 
                                            t     <- unifyPhiTypes l γ x t1 t2 θ
                                            return $ (t, a1, i1 `mappend` i2)
    _                                 -> die $ bugUnboundPhiVar (srcPos l) x

-- | `unifyPhiTypes` 
--
--   * Special casing the situation where one the types in undefined.
----------------------------------------------------------------------------------
unifyPhiTypes :: PPR r 
              => AnnSSA r
              -> TCEnv r 
              -> Var r 
              -> RType r 
              -> RType r 
              -> RSubst r 
              -> TCM r (RType r)
----------------------------------------------------------------------------------
unifyPhiTypes l γ x t1 t2 θ = 
  case unifys (srcPos l) γ θ [t1] [t2] of  
    Left  _               -> tcError $ errorEnvJoinUnif (srcPos l) x t1 t2
    Right θ' | apply θ' t1 == apply θ' t2 -> 
                      do setSubst θ' 
                         addAnn (ann_id l) $ PhiVarTy [(x, toType $ apply θ' t1)]
                         return t1
             | any isTUndef [t1,t2] -> do setSubst θ'
                                          addAnn (ann_id l) $ PhiVarTy [(x, toType $ apply θ' t12)]
                                          return t12
             | otherwise            -> tcError $ errorEnvJoin (srcPos l) x t1 t2
  where
    t12      = mkUnion [t1,t2]


forceCheck x γ = elem x $ fst <$> envToList (tce_names γ)


-- Local Variables:
-- flycheck-disabled-checkers: (haskell-liquid)
-- End:
