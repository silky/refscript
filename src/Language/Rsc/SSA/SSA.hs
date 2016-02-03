{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE TupleSections             #-}

module Language.Rsc.SSA.SSA (ssaTransform) where

import           Control.Arrow                ((***))
import           Control.Monad
import           Data.Data
import           Data.Default
import qualified Data.HashSet                 as S
import qualified Data.IntMap.Strict           as IM
import           Data.Maybe                   (catMaybes)
import           Data.Typeable                ()
import           Language.Fixpoint.Misc
import qualified Language.Fixpoint.Types      as F
import           Language.Rsc.Annotations
import           Language.Rsc.AST
import           Language.Rsc.ClassHierarchy
import           Language.Rsc.Core.Env
import           Language.Rsc.Errors
import           Language.Rsc.Locations
import           Language.Rsc.Misc
import           Language.Rsc.Names
import           Language.Rsc.Pretty
import           Language.Rsc.Program
import           Language.Rsc.SSA.SSAMonad
import           Language.Rsc.Typecheck.Types
import           Language.Rsc.Types
import           Language.Rsc.Visitor

-- import           Debug.Trace                        hiding (traceShow)

----------------------------------------------------------------------------------
ssaTransform :: (PP r, F.Reftable r, Data r)
             => BareRsc r -> ClassHierarchy r -> IO (Either FError (SsaRsc r))
----------------------------------------------------------------------------------
ssaTransform p cha = return $ execute p $ ssaRsc cha p


-- | `ssaRsc` Perfroms SSA transformation of the input program. The output
--   program is patched (annotated per AST) with information about:
--
--   * SSA-phi nodes
--   * Spec annotations (functions, global variable declarations)
--   * Type annotations (variable declarations (?), class elements)
--
----------------------------------------------------------------------------------
ssaRsc :: (Data r, PPR r) => ClassHierarchy r -> BareRsc r -> SSAM r (SsaRsc r)
----------------------------------------------------------------------------------
ssaRsc cha p@(Rsc { code = Src fs })
  = do  setMeas   $ S.fromList $ F.symbol <$> envIds (consts p)
        (_,fs')  <- ssaStmts g fs
        ssaAnns  <- getAnns
        ast_cnt  <- getCounter
        return    $ p { code  = Src $ (patch ssaAnns <$>) <$> fs'
                      , maxId = ast_cnt }
    where
      g = initGlobSsaEnv fs cha
      patch ms (FA i l fs) = FA i l (fs ++ IM.findWithDefault [] i ms)


-------------------------------------------------------------------------------------
ssaStmts :: (Data r, PPR r) => SsaEnv r -> [Statement (AnnSSA r)] -> SSAM r (Bool, [Statement (AnnSSA r)])
-------------------------------------------------------------------------------------------
ssaStmts g ss = mapSnd flattenBlock <$> ssaSeq (ssaStmt g) ss


-------------------------------------------------------------------------------------
ssaFun :: (Data r, PPR r)
       => SsaEnv r -> AnnSSA r -> [Var r] -> [Statement (AnnSSA r)]
       -> SSAM r [Statement (AnnSSA r)]
-------------------------------------------------------------------------------------
ssaFun g l xs body
  = do  γ0         <- getSsaVars                  -- Remember env before the function
        setSsaVars  $ mempty                      -- Reset the 'local' SSA-vars count
        body1      <- pure body                   -- prefixArgInit l body
        g'         <- initCallableSsaEnv l g xs body1
        (_, body2) <- ssaStmts g' body1
        setSsaVars  $ γ0                          -- Restore outer env
        return      $ body2

-------------------------------------------------------------------------------------
ssaSeq :: (a -> SSAM r (Bool, a)) -> [a] -> SSAM r (Bool, [a])
-------------------------------------------------------------------------------------
ssaSeq f            = go True
  where
    go False zs     = return (False, zs)
    go b     []     = return (b    , [])
    go True  (x:xs) = do (b , y)  <- f x
                         (b', ys) <- go b xs
                         return      (b', y:ys)

-----------------------------------------------------------------------------------
ssaStmt :: (Data r, PPR r) => SsaEnv r -> Statement (AnnSSA r) -> SSAM r (Bool, Statement (AnnSSA r))
-----------------------------------------------------------------------------------
-- skip
ssaStmt _ s@(EmptyStmt _)
  = return (True, s)

-- interface IA<V> extends IB<T> { ... }
ssaStmt _ s@(InterfaceStmt _ _)
  = return (True, s)

-- x = e
ssaStmt g (ExprStmt l1 (AssignExpr l2 OpAssign (LVar l3 v) e)) = do
    let x        = Id l3 v
    (s, x', e') <- ssaAsgn g l2 x e
    return         (True, prefixStmt l1 s $ ssaAsgnStmt l1 l2 x x' e')

-- e
ssaStmt g (ExprStmt l e) = do
    (s, e') <- ssaExpr g e
    return (True, prefixStmt l s $ ExprStmt l e')

-- s1;s2;...;sn
ssaStmt g (BlockStmt l stmts) = do
    (b, stmts') <- ssaStmts g stmts
    return (b,  maybeBlock l $ flattenBlock stmts')

-- if b { s1 }
ssaStmt g (IfSingleStmt l b s)
  = ssaStmt g (IfStmt l b s (EmptyStmt l))

-- if (e1 || e2) { s1 } else { s2 }
ssaStmt g (IfStmt l (InfixExpr _ OpLOr e1 e2) s1 s2)
  = ssaExpandIfStmtInfixOr l e1 e2 s1 s2 >>= ssaStmt g

-- if (e1 && e2) { s1 } else { s2 }
ssaStmt g (IfStmt l (InfixExpr _ OpLAnd e1 e2) s1 s2)
  = ssaExpandIfStmtInfixAnd l e1 e2 s1 s2 >>= ssaStmt g

-- if b { s1 } else { s2 }
ssaStmt g (IfStmt l e s1 s2)
  = do  (se, e')     <- ssaExpr g e
        θ            <- getSsaVars
        (θ1, s1')    <- ssaWith θ (ssaStmt g) s1
        (θ2, s2')    <- ssaWith θ (ssaStmt g) s2
        (phis, θ', φ1, φ2) <- envJoin l g θ1 θ2
        case θ' of
          Just θ''   -> do  setSsaVars      θ''
                            latest       <- catMaybes <$> mapM findSsaEnv phis
                            new          <- mapM (updSsaEnv g l) phis
                            addAnn l      $ PhiPost $ zip3 phis latest new
                            let stmt'     = prefixStmt l se
                                          $ IfStmt l e' (splice s1' φ1) (splice s2' φ2)
                            return          (True,  stmt')

          Nothing    ->     let stmt'     = prefixStmt l se
                                          $ IfStmt l e' (splice s1' φ1) (splice s2' φ2) in
                            return (False, stmt')

--
--   while (i <- f(i) ; cond(i)) { <BODY> }
--
--   ===>
--
--   i = f(i); while (cond(i)) { <BODY>; i = f(i); }
--
ssaStmt g (WhileStmt l cnd body)
  = do  (xs, x0s)         <- unzip <$> getLoopPhis g body
        xs'               <- mapM freshenIdSSA xs
        let as            = map (\x -> getAssignability g x WriteLocal) xs
        let (l1s, l0s,_)  = unzip3 $ filter ((== WriteLocal) . thd3) (zip3 xs' x0s as)
        --
        -- SSA only the WriteLocal variables - globals will remain the same.
        --
        l1s'              <- mapM (updSsaEnv g l) l1s
        θ1                <- getSsaVars
        (sc, cnd')        <- ssaExpr g cnd
        unless (null sc) (ssaError $ errorUpdateInExpr (srcPos l) cnd)
        (t, body')        <- ssaStmt g body
        θ2                <- getSsaVars
        --
        -- SSA only the WriteLocal variables - globals will remain the same.
        --
        let l2s            = [ x2 | (Just x2, WriteLocal) <- mapFst (`envFindTy` θ2) <$> zip xs as ]
        addAnn l           $ PhiVar l1s'
        setSsaVars           θ1
        l'                <- freshenAnn l
        let body''         = body' `splice` asgn l' (mkNextId <$> l1s') l2s
        l''               <- freshenAnn l
        return               (t, asgn l'' l1s' l0s `presplice` WhileStmt l cnd' body'')
    where
        asgn _  [] _       = Nothing
        asgn l' ls rs      = Just $ maybeBlock l' $ zipWith (mkPhiAsgn l') ls rs

ssaStmt _ (ForStmt _  NoInit _ _ _ )     =
    errorstar "unimplemented: ssaStmt-for-01"

ssaStmt g (ForStmt l v cOpt (Just (UnaryAssignExpr l1 o lv)) b) =
    ssaStmt g (ForStmt l v cOpt (Just $ AssignExpr l1 (op o) lv (IntLit l1 1)) b)
  where
    op PrefixInc   = OpAssignAdd
    op PrefixDec   = OpAssignSub
    op PostfixInc  = OpAssignAdd
    op PostfixDec  = OpAssignSub

ssaStmt g (ForStmt l (VarInit vds) cOpt (Just e@(AssignExpr l1 _ _ _)) b) =
    ssaForLoop g l vds cOpt (Just $ ExprStmt l1 (expand e)) b
  where
    expand (AssignExpr l1 o lv e) = AssignExpr l1 OpAssign lv (infOp o l1 lv e)
    expand _ = errorstar "unimplemented: expand assignExpr"

ssaStmt g (ForStmt l (VarInit vds) cOpt (Just i) b) =
    ssaForLoop g l vds cOpt (Just $ ExprStmt (getAnnotation i) i) b

ssaStmt g (ForStmt l (VarInit vds) cOpt Nothing  b) =
    ssaForLoop g l vds cOpt Nothing b


ssaStmt g (ForStmt l (ExprInit ei) cOpt (Just e@(AssignExpr l1 _ _ _)) b) =
    ssaForLoopExpr g l ei cOpt (Just $ ExprStmt l1 (expand e)) b
  where
    expand (AssignExpr l1 o lv e) = AssignExpr l1 OpAssign lv (infOp o l1 lv e)
    expand _ = errorstar "unimplemented: expand assignExpr"

ssaStmt g (ForStmt l (ExprInit e) cOpt (Just i) b) =
    ssaForLoopExpr g l e cOpt (Just $ ExprStmt (getAnnotation i) i) b

ssaStmt g (ForStmt l (ExprInit e) cOpt Nothing  b) =
    ssaForLoopExpr g l e cOpt Nothing b


-- | for (var k in obj) { <body> }
--
--      ==>
--
--   var _keys = builtin_BIForInKeys(obj);
--               // Array<Imm, { v: string | (keyIn(v,obj) && enumProp(v,obj)) }>
--
--   for (var _i = 0; _i < _keys.length; _i++) {
--     var k = _keys[_i];
--
--     <body>
--
--   }

ssaStmt g (ForInStmt l (ForInVar v) e b) =
    do  init_  <- initArr
        for_   <- forStmt
        ssaStmt g $ maybeBlock l [init_, for_]
  where
    fr          = fr_ l
    biForInKeys = return $ builtinId "BIForInKeys"

    initArr     = vStmt $ VarDecl <$> fr
                                  <*> keysArr
                                  <*> justM (CallExpr <$> fr
                                                      <*> (VarRef <$> fr <*> biForInKeys)
                                                      <**> [e])
    initIdx     = VarDecl <$> fr
                          <*> keysIdx
                          <*> (Just      <$> (IntLit  <$> fr <**> 0))
    condition   = Just    <$> (InfixExpr <$> fr
                                         <*> return OpLT
                                         <*> (VarRef  <$> fr <*> keysIdx)
                                         <*> (DotRef  <$> fr
                                                      <*> (VarRef <$> fr <*> keysArr)
                                                      <*> (Id     <$> fr <**> "length")
                                             ))
    increment   = Just <$> (UnaryAssignExpr
                                      <$> fr
                                      <*> return PostfixInc
                                      <*> (LVar    <$> fr
                                                   <*> (unId <$> keysIdx)))
    accessKeys  = vStmt $ VarDecl <$> fr
                                  <*> return v
                                  <*> justM (BracketRef <$> fr
                                                        <*> (VarRef <$> fr <*> keysArr)
                                                        <*> (VarRef <$> fr <*> keysIdx))
    forStmt     = ForStmt <$> fr
                          <*> (VarInit . single <$> initIdx)
                          <*> condition
                          <*> increment
                          <*> (maybeBlock <$> fr
                                         <*> ( (:[b]) <$> accessKeys))

    vStmt v     = VarDeclStmt <$> fr <*> (single <$> v)

    keysArr     = return $ mkKeysId    v
    keysIdx     = return $ mkKeysIdxId v

    mkId        = Id (FA def def def)
    builtinId s = mkId ("builtin_" ++ s)



-- var x1 [ = e1 ]; ... ; var xn [= en];
ssaStmt g (VarDeclStmt l ds) = do
    stvds' <- mapM (ssaVarDecl g) ds
    return    (True, mkStmt $ foldr crunch ([], []) stvds')
  where
    crunch ([], d) (ds, ss') = (d:ds, ss')
    crunch (ss, d) (ds, ss') = ([]  , mkStmts l ss (d:ds) ss')
    mkStmts l ss ds ss'      = ss ++ VarDeclStmt l ds : ss'
    mkStmt (ds', [] )        = VarDeclStmt l ds'
    mkStmt (ds', ss')        = maybeBlock l (mkStmts l [] ds' ss')

-- return e
ssaStmt _ s@(ReturnStmt _ Nothing)
  = return (False, s)

-- return e
ssaStmt g (ReturnStmt l (Just e)) = do
    (s, e') <- ssaExpr g e
    return (False, prefixStmt l s $ ReturnStmt l (Just e'))

-- throw e
ssaStmt g (ThrowStmt l e) = do
    (s, e') <- ssaExpr g e
    return (False, prefixStmt l s $ ThrowStmt l e')


-- function f(...){ s }
ssaStmt g (FunctionStmt l f xs (Just bd))
  = do  g'        <- initCallableSsaEnv l g xs bd
        (True,) . FunctionStmt l f xs . Just <$> ssaFun g' l xs bd

ssaStmt _ s@(FunctionStmt _ _ _ Nothing)
  = return (True, s)

-- switch (e) { ... }
ssaStmt g (SwitchStmt l e xs)
  = do
      id <- updSsaEnv g (an e) (Id (an e) "__switchVar")
      let go (l, e, s) = IfStmt (an s) (InfixExpr l OpStrictEq (VarRef l id) e) s
      mapSnd (maybeBlock l) <$> ssaStmts g
        [ VarDeclStmt (an e) [VarDecl (an e) id (Just e)], foldr go z sss ]
  where
      an                   = getAnnotation
      sss                  = [ (l, e, maybeBlock l $ remBr ss) | CaseClause l e ss <- xs ]
      z                    = headWithDefault (EmptyStmt l) [maybeBlock l $ remBr ss | CaseDefault l ss <- xs]

      remBr                = filter (not . isBr) . flattenBlock
      isBr (BreakStmt _ _) = True
      isBr _               = False
      headWithDefault a [] = a
      headWithDefault _ xs = head xs

-- class A extends B implements I,J,... { ... }
ssaStmt g c@(ClassStmt l n bd)
  = (True,) . ClassStmt l n <$> mapM (ssaClassElt g' c) bd
  where
    g' = initClassSsaEnv l g n

-- module M { ... }
ssaStmt g (ModuleStmt l n body)
  = do  g' <- pure (initModuleSsaEnv l g n body)
        (True,) . ModuleStmt l n . snd <$> ssaStmts g' body

-- enum { ... }
ssaStmt _ (EnumStmt l n es)
  = return (True, EnumStmt l n es)

-- OTHER (Not handled)
ssaStmt _ s
  = convertError "ssaStmt" s


ssaAsgnStmt l1 l2 x@(Id l3 v) x' e'
  | x == x'   = ExprStmt l1    (AssignExpr l2 OpAssign (LVar l3 v) e')
  | otherwise = VarDeclStmt l1 [VarDecl l2 x' (Just e')]

-- | Freshen annotation shortcut
--
fr_ = freshenAnn

-------------------------------------------------------------------------------------
ctorVisitor :: (Data r, PPR r) => SsaEnv r -> [Id (AnnSSA r)] -> VisitorM (SSAM r) () () (AnnSSA r)
-------------------------------------------------------------------------------------
ctorVisitor g ms          = defaultVisitor { endStmt = es } { endExpr = ee }
                                           { mStmt   = ts } { mExpr   = te }
  where
    es FunctionStmt{}     = True
    es _                  = False
    ee FuncExpr{}         = True
    ee _                  = False

    te (AssignExpr la OpAssign (LDot ld (ThisRef _) s) e)
                          = AssignExpr <$> fr_ la
                                       <*> return OpAssign
                                       <*> (LVar <$> fr_ ld <**> mkCtorStr s)
                                       <*> return e
    te lv                 = return lv

    ts (ExprStmt _ (CallExpr l (SuperRef _) es))
      = do  svs     <- superVS parent
            flds    <- mapM asgnS fields
            let body = svs : flds
            l'      <- fr_ l
            return   $ maybeBlock l' body
      where
        fr     = fr_ l
        cha    = ssaCHA g

        fields | Just n <- curClass g
               = inheritedNonStaticFields cha n
               | otherwise
               = []

        parent | Just n <- curClass g,
                 Just (TD (TS _ _ ([Gen (QN path name) _],_)) _ ) <- resolveType cha n
               = case path of
                   QP _ _ []     -> VarRef <$> fr <*> (Id <$> fr <**> F.symbolSafeString name)
                   QP _ _ (y:ys) -> do init <- VarRef <$> fr <*> (Id <$> fr <**> F.symbolSafeString y)
                                       foldM (\e q -> DotRef <$> fr <*> return e
                                                                    <*> (Id <$> fr <**> F.symbolSafeString q)) init (ys ++ [name])
               | otherwise = ssaError $ bugSuperWithNoParent (srcPos l)

        superVS n = VarDeclStmt <$> fr <*> (single <$> superVD n)
        superVD n = VarDecl  <$> fr
                             <*> freshenIdSSA (builtinOpId BISuperVar)
                             <*> justM (NewExpr <$> fr <*> n <**> es)
        asgnS x = ExprStmt   <$> fr <*> asgnE x
        asgnE x = AssignExpr <$> fr
                             <*> return OpAssign
                             <*> (LDot <$> fr <*> (ThisRef <$> fr) <**> F.symbolSafeString x)
                             <*> (DotRef <$> fr
                                         <*> (VarRef <$> fr <*> freshenIdSSA (builtinOpId BISuperVar))
                                         <*> (Id <$> fr <**> F.symbolSafeString x))

    ts r@(ReturnStmt l _) = maybeBlock <$> fr_ l <*> ((:[r]) <$> ctorExit l ms)
    ts r                  = return r

-------------------------------------------------------------------------------------
ctorExit :: AnnSSA r -> [Id t] -> SSAM r (Statement (AnnSSA r))
-------------------------------------------------------------------------------------
ctorExit l ms
  = do  m     <- VarRef <$> fr <*> freshenIdSSA (builtinOpId BICtorExit)
        es    <- mapM ((VarRef <$> fr <*>) . return . mkCtorId l) ms
        ReturnStmt <$> fr <*> justM (CallExpr <$> fr <**> m <**> es)
  where
    fr = fr_ l


-- | Constructor Transformation
--
--  constructor() {
--
--    this.x = 1;
--    this.y = "sting";
--    if () {  this.x = 2; }
--
--  }
--
--          ||
--          vv
--
--  constructor() {
--
--    var _ctor_x_0 = 1;                        // preM
--    var _ctor_y_1 = "string"
--
--    if () { _ctor_x_2 = 2; }                  // bdM
--    // _ctor_x_3 = φ(_ctor_x_2,_ctor_x_0);
--
--    return _ctor_exit(_ctor_x_3,_ctor_y_1);   // exitM
--
--  }
--
-------------------------------------------------------------------------------------
ssaClassElt :: (Data r, PPR r) => SsaEnv r -> Statement (AnnSSA r)
            -> ClassElt (AnnSSA r) -> SSAM r (ClassElt (AnnSSA r))
-------------------------------------------------------------------------------------
ssaClassElt g c (Constructor l xs bd)
  = do  pre       <- preM c
        fs        <- mapM symToVar fields
        bfs       <- bdM fs
        efs       <- exitM fs
        bd'       <- pure (pre ++ bfs ++ efs)
        g'        <- initCallableSsaEnv l g xs bd'
        (_, bd'') <- ssaStmts g' bd'
        return     $ Constructor l xs bd''
  where
    symToVar       = freshenIdSSA . mkId . F.symbolSafeString
    cha            = ssaCHA g
    fields         | Just n <- curClass g = nonStaticFields cha n
                   | otherwise            = []
    bdM fs         = visitStmtsT (ctorVisitor g fs) () bd
    exitM  fs      = single <$> ctorExit l fs


-- | Initilization expression for instance variables is moved to the beginning
--   of the constructor.
ssaClassElt _ _ (MemberVarDecl l False x _)
  = return $ MemberVarDecl l False x Nothing

ssaClassElt g _ (MemberVarDecl l True x (Just e))
  = do z <- ssaExpr g e
       case z of
         ([], e') -> return $ MemberVarDecl l True x (Just e')
         _        -> ssaError $ errorEffectInFieldDef (srcPos l)

ssaClassElt _ _ (MemberVarDecl l True x Nothing)
  = ssaError $ errorUninitStatFld (srcPos l) x

ssaClassElt g _ (MemberMethDecl l s e xs body)
  = MemberMethDecl l s e xs <$> ssaFun g l xs body


preM (ClassStmt _ _ cs)
  = do  xs'      <- mapM freshenIdSSA xs
        zipWith3M f ls xs' es
  where
    fr            = freshenAnn
    (ls, xs, es)  = unzip3 [ (l, mkCtorId l x, e) | MemberVarDecl l False x (Just e) <- cs ]
    f l x e       = VarDeclStmt <$> fr l <*> (single <$> g l x e)
    g l x e       = VarDecl     <$> fr l <*> freshenIdSSA x <*> (Just <$> pure e)

preM _ = return []


-- | Expand: [[ if ( e1 || e2) { s1 } else { s2 } ]]
--
--      let r = false;
--      if ( [[ e1 ]] ) {       // IF1
--          r = true;           // RT1
--      }
--      else {
--          if ( [[ e2 ]] ) {   // IF2
--              r = true;       // RT2
--          }
--      }
--      if ( r ) {
--          [[ s1 ]]
--      }
--      else {
--          [[ s2 ]]
--      }
--
ssaExpandIfStmtInfixOr l e1 e2 s1 s2
  = do  n     <- ("lor_" ++) . show  <$> tick
        -- R1 ::= var r_NN = false;
        r     <- Id           <$> fr l <**> n
        fls   <- BoolLit      <$> fr l <**> False
        vd    <- VarDecl      <$> fr l <**> r <**> Just fls
        vs    <- VarDeclStmt  <$> fr l <**> [vd]
        -- RT1 ::= r = true;
        tru1  <- BoolLit      <$> fr l <**> True
        lv1   <- LVar         <$> fr l <**> n
        ae1   <- AssignExpr   <$> fr l <**> OpAssign <**> lv1 <**> tru1
        as1   <- ExprStmt     <$> fr l <**> ae1
        -- RT2 ::= r = true;
        tru2  <- BoolLit      <$> fr l <**> True
        lv2   <- LVar         <$> fr l <**> n
        ae2   <- AssignExpr   <$> fr l <**> OpAssign <**> lv2 <**> tru2
        as2   <- ExprStmt     <$> fr l <**> ae2
        -- IF2 ::= if ( e2 ) { r = true } else { }
        if2   <- IfSingleStmt <$> fr l <**> e2 <**> as2
        -- IF1 ::= if ( e1 ) { r = true } else { if ( e2 ) { r = true } }
        if1   <- IfStmt       <$> fr l <**> e1 <**> as1 <**> if2
        -- if ( r ) { s1 } else { s2 }
        r3    <- Id           <$> fr l <**> n
        v3    <- VarRef       <$> fr l <**> r3
        if3   <- IfStmt       <$> fr l <**> v3 <**> s1 <**> s2
        maybeBlock            <$> fr l <**> [vs, if1, if3]
  where
    fr = freshenAnn

-- | Expand: [[ if ( e1 && e2) { s1 } else { s2 } ]]
--
--      let r = true;
--      if ( [[ e1 ]] ) {
--          if ( [[ e2 ]] ) {
--
--          }
--          else {
--              r = false;
--          }
--      }
--      else {
--          r = false;
--      }
--      if ( r ) {
--          [[ s1 ]]
--      }
--      else {
--          [[ s2 ]]
--      }
--
ssaExpandIfStmtInfixAnd l e1 e2 s1 s2
  = do  n     <- ("land_" ++) . show  <$> tick
        -- var r_NN = true;
        r     <- Id           <$> fr l <**> n
        fls   <- BoolLit      <$> fr l <**> True
        vd    <- VarDecl      <$> fr l <**> r <**> Just fls
        vs    <- VarDeclStmt  <$> fr l <**> [vd]
        -- r = false;
        tru1  <- BoolLit      <$> fr l <**> False
        lv1   <- LVar         <$> fr l <**> n
        ae1   <- AssignExpr   <$> fr l <**> OpAssign <**> lv1 <**> tru1
        as1   <- ExprStmt     <$> fr l <**> ae1
        -- IF2 ::= if ( e2 ) {  } else { r = false; }
        emp   <- EmptyStmt    <$> fr l
        if2   <- IfStmt       <$> fr l <**> e2 <**> emp <**> as1
        -- AS2 ::= r = false;
        tru2  <- BoolLit      <$> fr l <**> False
        lv2   <- LVar         <$> fr l <**> n
        ae2   <- AssignExpr   <$> fr l <**> OpAssign <**> lv2 <**> tru2
        as2   <- ExprStmt     <$> fr l <**> ae2
        -- IF1 ::= if ( e1 ) { IF2 } else { AS2 }
        if1   <- IfStmt       <$> fr l <**> e1 <**> if2 <**> as2
        -- if ( r ) { s1 } else { s2 }
        r3    <- Id           <$> fr l <**> n
        v3    <- VarRef       <$> fr l <**> r3
        if3   <- IfStmt       <$> fr l <**> v3 <**> s1 <**> s2
        maybeBlock            <$> fr l <**> [vs, if1, if3]
  where
    fr = freshenAnn


infOp OpAssign         _ _  = id
infOp OpAssignAdd      l lv = InfixExpr l OpAdd      (lvalExp lv)
infOp OpAssignSub      l lv = InfixExpr l OpSub      (lvalExp lv)
infOp OpAssignMul      l lv = InfixExpr l OpMul      (lvalExp lv)
infOp OpAssignDiv      l lv = InfixExpr l OpDiv      (lvalExp lv)
infOp OpAssignMod      l lv = InfixExpr l OpMod      (lvalExp lv)
infOp OpAssignLShift   l lv = InfixExpr l OpLShift   (lvalExp lv)
infOp OpAssignSpRShift l lv = InfixExpr l OpSpRShift (lvalExp lv)
infOp OpAssignZfRShift l lv = InfixExpr l OpZfRShift (lvalExp lv)
infOp OpAssignBAnd     l lv = InfixExpr l OpBAnd     (lvalExp lv)
infOp OpAssignBXor     l lv = InfixExpr l OpBXor     (lvalExp lv)
infOp OpAssignBOr      l lv = InfixExpr l OpBOr      (lvalExp lv)

lvalExp (LVar l s)          = VarRef l (Id l s)
lvalExp (LDot l e s)        = DotRef l e (Id l s)
lvalExp (LBracket l e1 e2)  = BracketRef l e1 e2

-------------------------------------------------------------------------------------
presplice :: Maybe (Statement (AnnSSA r)) -> Statement (AnnSSA r) -> Statement (AnnSSA r)
-------------------------------------------------------------------------------------
presplice z s' = splice_ (getAnnotation s') z (Just s')

-------------------------------------------------------------------------------------
splice :: Statement a -> Maybe (Statement a) -> Statement a
-------------------------------------------------------------------------------------
splice s = splice_ (getAnnotation s) (Just s)

splice_ l Nothing Nothing    = EmptyStmt l
splice_ _ (Just s) Nothing   = s
splice_ _ Nothing (Just s)   = s
splice_ _ (Just s) (Just s') = seqStmt (getAnnotation s) s s'


seqStmt _ (BlockStmt l s) (BlockStmt _ s') = maybeBlock l (s ++ s')
seqStmt l s s'                             = maybeBlock l [s, s']

-------------------------------------------------------------------------------------
prefixStmt :: a -> [Statement a] -> Statement a -> Statement a
-------------------------------------------------------------------------------------
prefixStmt l ss s = maybeBlock l (ss ++ [s])

-------------------------------------------------------------------------------------
maybeBlock :: a -> [Statement a] -> Statement a
-------------------------------------------------------------------------------------
maybeBlock l [ ]  = EmptyStmt l
maybeBlock _ [s]  = s
maybeBlock l ss   = BlockStmt l ss

-------------------------------------------------------------------------------------
flattenBlock :: [Statement t] -> [Statement t]
-------------------------------------------------------------------------------------
flattenBlock = concatMap f
  where
    f (BlockStmt _ ss) = ss
    f s                = [s]

-------------------------------------------------------------------------------------
ssaWith :: Env (Var r) -> (a -> SSAM r (Bool, b)) -> a -> SSAM r (Maybe (Env (Var r)), b)
-------------------------------------------------------------------------------------
ssaWith θ f x
  = do  setSsaVars θ
        (b, x') <- f x
        (,x') <$> go b
  where
    go b | b         = Just <$> getSsaVars
         | otherwise = pure Nothing

-------------------------------------------------------------------------------------
ssaExpr :: (Data r, PPR r) => SsaEnv r -> Expression (AnnSSA r) -> SSAM r ([Statement (AnnSSA r)], Expression (AnnSSA r))
-------------------------------------------------------------------------------------

ssaExpr _ e@(IntLit _ _)
  = return ([], e)

ssaExpr _ e@(HexLit _ _)
  = return ([], e)

ssaExpr _ e@(BoolLit _ _)
  = return ([], e)

ssaExpr _ e@(StringLit _ _)
  = return ([], e)

ssaExpr _ e@(NullLit _)
  = return ([], e)

ssaExpr _ e@(ThisRef _)
  = return ([], e)

ssaExpr _ e@(SuperRef _)
  = return ([], e)

ssaExpr g   (ArrayLit l es)
  = ssaExprs g (ArrayLit l) es

-- | arguemnts ==> __getArguemnts()
--
ssaExpr g (VarRef l x)
  | F.symbol x == argSym
  = do  aId   <- freshenIdSSA (getArgId l)
        aVr   <- VarRef   <$> freshenAnn l <*> pure aId
        cExp  <- CallExpr <$> freshenAnn l <*> pure aVr <*> pure []
        ssaExpr g cExp

ssaExpr g (VarRef l x)
  = ([],) <$> ssaVarRef g l x

ssaExpr g (CondExpr l c e1 e2)
  = do (sc, c') <- ssaExpr g c
       θ        <- getSsaVars
       e1'      <- ssaPureExprWith θ g e1
       e2'      <- ssaPureExprWith θ g e2
       return (sc, CondExpr l c' e1' e2')

ssaExpr g (PrefixExpr l o e)
  = ssaExpr1 g (PrefixExpr l o) e

ssaExpr _ e@(InfixExpr l OpLOr _ _)
  = ssaError $ unimplementedInfix l e

ssaExpr g (InfixExpr l o e1 e2)
  = ssaExpr2 g (InfixExpr l o) e1 e2

ssaExpr _ e@(CallExpr _ (SuperRef _) _)
  = ssaError $ bugSuperNotHandled (srcPos e) e

ssaExpr g (CallExpr l e es)
  = ssaExprs g (\es' -> CallExpr l (head es') (tail es')) (e : es)

ssaExpr g (ObjectLit l ps)
  = ssaExprs g (ObjectLit l . zip fs) es
  where
    (fs, es) = unzip ps

ssaExpr g (DotRef l e i)
  = ssaExpr1 g (\e' -> DotRef l e' i) e

ssaExpr g (BracketRef l e1 e2)
  = ssaExpr2 g (BracketRef l) e1 e2

ssaExpr g (NewExpr l e es)
  = ssaExprs g (\es' -> NewExpr l (head es') (tail es')) (e:es)

ssaExpr g (Cast l e)
  = ssaExpr1 g (Cast l) e

ssaExpr g (FuncExpr l fo xs bd)
  = ([],) . FuncExpr l fo xs <$> ssaFun g l xs bd

-- x = e
ssaExpr g (AssignExpr l OpAssign (LVar lx v) e)
  = ssaAsgnExpr g l lx (Id lx v) e

-- e1.f = e2
ssaExpr g (AssignExpr l OpAssign (LDot ll e1 f) e2)
  = ssaExpr2 g (\e1' e2' -> AssignExpr l OpAssign (LDot ll e1' f) e2') e1 e2

-- e1[e2] = e3
ssaExpr g (AssignExpr l OpAssign (LBracket ll e1 e2) e3)
  = ssaExpr3 g (\e1' e2' e3' -> AssignExpr l OpAssign (LBracket ll e1' e2') e3') e1 e2 e3

-- lv += e
ssaExpr g (AssignExpr l op lv e)
  = ssaExpr g (AssignExpr l OpAssign lv rhs)
  where
    rhs = InfixExpr l (assignInfix op) (lvalExp lv) e

-- x++
ssaExpr g (UnaryAssignExpr l uop (LVar lv v))
  = do let x           = Id lv v
       xOld           <- ssaVarRef g l x
       xNew           <- updSsaEnv g l x
       let (eIn, eOut) = unaryExprs l uop xOld (VarRef l xNew)
       return  ([ssaAsgnStmt l lv x xNew eIn], eOut)

-- lv++
ssaExpr g (UnaryAssignExpr l uop lv)
  = do lv'   <- ssaLval g lv
       let e' = unaryExpr l uop (lvalExp lv')
       return ([], AssignExpr l OpAssign lv' e')

ssaExpr _ e
  = convertError "ssaExpr" e

ssaAsgnExpr g l lx x e
  = do (s, x', e') <- ssaAsgn g l x e
       return       $ (s ++ [ssaAsgnStmt l lx x x' e'], e')

-----------------------------------------------------------------------------
ssaLval :: (Data r, PPR r) => SsaEnv r -> LValue (AnnSSA r) -> SSAM r (LValue (AnnSSA r))
-----------------------------------------------------------------------------
ssaLval g (LVar lv v)
  = do VarRef _ (Id _ v') <- ssaVarRef g lv (Id lv v)
       return (LVar lv v')

ssaLval g (LDot ll e f)
  = (\e' -> LDot ll e' f) <$> ssaPureExpr g e

ssaLval g (LBracket ll e1 e2)
  = LBracket ll <$> ssaPureExpr g e1 <*> ssaPureExpr g e2


--------------------------------------------------------------------------
-- | Helpers for gathering assignments for purifying effectful-expressions
--------------------------------------------------------------------------

ssaExprs g f es = (concat *** f) . unzip <$> mapM (ssaExpr g) es

ssaExpr1 = case1 . ssaExprs
ssaExpr2 = case2 . ssaExprs
ssaExpr3 = case3 . ssaExprs

ssaPureExprWith θ g e = snd <$> ssaWith θ (fmap (True,) . ssaPureExpr g) e

ssaPureExpr g e = do
  (s, e') <- ssaExpr g e
  case s of
    []     -> return e'
    _      -> ssaError $ errorUpdateInExpr (srcPos e) e

--------------------------------------------------------------------------
-- | Dealing with Generic Assignment Expressions
--------------------------------------------------------------------------
assignInfix :: AssignOp -> InfixOp
assignInfix OpAssignAdd      = OpAdd
assignInfix OpAssignSub      = OpSub
assignInfix OpAssignMul      = OpMul
assignInfix OpAssignDiv      = OpDiv
assignInfix OpAssignMod      = OpMod
assignInfix OpAssignLShift   = OpLShift
assignInfix OpAssignSpRShift = OpSpRShift
assignInfix OpAssignZfRShift = OpZfRShift
assignInfix OpAssignBAnd     = OpBAnd
assignInfix OpAssignBXor     = OpBXor
assignInfix OpAssignBOr      = OpBOr
assignInfix o                = error $ "assignInfix called with " ++ ppshow o


--------------------------------------------------------------------------
-- | Dealing with Unary Expressions
--------------------------------------------------------------------------

unaryExprs l u xOld xNew = (unaryExpr l u xOld, unaryId xOld xNew u)

unaryExpr l u e1         = InfixExpr l bop e1 (IntLit l 1)
  where
    bop                  = unaryBinOp u

unaryBinOp PrefixInc     = OpAdd
unaryBinOp PostfixInc    = OpAdd
unaryBinOp _             = OpSub
unaryId _ x PrefixInc    = x
unaryId _ x PrefixDec    = x
unaryId x _ _            = x


-------------------------------------------------------------------------------------
ssaVarDecl :: (Data r, PPR r)
           => SsaEnv r -> VarDecl (AnnSSA r) -> SSAM r ([Statement (AnnSSA r)], VarDecl (AnnSSA r))
-------------------------------------------------------------------------------------
ssaVarDecl g (VarDecl l x (Just e)) = do
    (s, e') <- ssaExpr g e
    x'      <- initSsaVar g l x
    return    (s, VarDecl l x' (Just e'))

ssaVarDecl g v@(VarDecl l x Nothing)
  | Ambient `elem` map thd4 (scrapeVarDecl v)     -- declare var a;
  = return ([], VarDecl l x Nothing)
  | RdOnly `elem` map thd4 (scrapeVarDecl v)
  = ssaError $ errorReadOnlyUninit l x
  | otherwise
  = ([],) <$> (VarDecl l <$> updSsaEnv g l x
                         <*> justM (VarRef <$> fr_ l <*> freshenIdSSA undefinedId))

------------------------------------------------------------------------------------------
ssaVarRef :: (Data r, PPR r) => SsaEnv r -> AnnSSA r -> Id (AnnSSA r) -> SSAM r (Expression (AnnSSA r))
------------------------------------------------------------------------------------------
ssaVarRef g l x
  = case getAssignability g x WriteLocal of
      WriteGlobal  -> return e
      Ambient      -> return e
      RdOnly       -> return e
      WriteLocal   -> findSsaEnv x >>= \case
                        Just t   -> return   $ VarRef l t
                        Nothing  -> return   $ VarRef l x
      ForeignLocal -> ssaError $ errorForeignLocal (srcPos x) x
      ReturnVar    -> ssaError $ errorSSAUnboundId (srcPos x) x
    where
       e = VarRef l x

------------------------------------------------------------------------------------
ssaAsgn :: (Data r, PPR r)
        => SsaEnv r
        -> AnnSSA r
        -> Id (AnnSSA r)
        -> Expression (AnnSSA r)
        -> SSAM r ([Statement (AnnSSA r)], Id (AnnSSA r), Expression (AnnSSA r))
------------------------------------------------------------------------------------
ssaAsgn g l x e  = do
    (s, e') <- ssaExpr g e
    x'      <- updSsaEnv g l x
    return (s, x', e')

-------------------------------------------------------------------------------------
envJoin :: Data r
        => AnnSSA r
        -> SsaEnv r
        -> Maybe (Env (Var r))
        -> Maybe (Env (Var r))
        -> SSAM r ([Var r], Maybe (Env (Var r)), Maybe (Statement (AnnSSA r)), Maybe (Statement (AnnSSA r)))
-------------------------------------------------------------------------------------
envJoin _ _ Nothing Nothing     = return ([], Nothing, Nothing, Nothing)
envJoin _ _ Nothing (Just θ)    = return ([], Just θ , Nothing, Nothing)
envJoin _ _ (Just θ) Nothing    = return ([], Just θ , Nothing, Nothing)
envJoin l g (Just θ1) (Just θ2) = envJoin' l g θ1 θ2

envJoin' l g θ1 θ2
  = do  setSsaVars θ'                                   -- Keep common (unchanged) binders
        phis       <- mapM (mapFstM freshenIdSSA) φ     -- New Φ-vars
        (s1, s2)   <- unzip <$> mapM (phiAsgn l g) phis -- Add Φ-vars, Φ-Annotations, Return Stmts
        θ''        <- getSsaVars
        return      ( fst <$> phis                      -- Φ-vars
                    , Just θ''
                    , Just (maybeBlock l s1)
                    , Just (maybeBlock l s2)
                    )
  where
    θ           = envIntersectWith meet θ1 θ2
    θ'          = envRights θ                           -- Unchanged vars
    φ           = envToList $ envLefts θ                -- Φ-vars
    x `meet` y  | x == y    = Right x
                | otherwise = Left (x, y)


phiAsgn l g (x, (x1, x2))
  = do  x' <- updSsaEnv g l x                           -- Generate FRESH Φ-var
        addAnn l (PhiVar [x'])                          -- RECORD x' as PHI-Var at l
        let s1 = mkPhiAsgn l x' x1                      -- Create Phi-Assignments
        let s2 = mkPhiAsgn l x' x2                      -- for both branches
        return (s1, s2)

-------------------------------------------------------------------------------------
mkPhiAsgn :: AnnSSA r -> Id (AnnSSA r) -> Id (AnnSSA r) -> Statement (AnnSSA r)
-------------------------------------------------------------------------------------
mkPhiAsgn l x y = VarDeclStmt l [VarDecl l x (Just $ VarRef l y)]


-- | `getLoopPhis g b` returns a list with the Φ-vars of the body @b@ of the
--   loop (the source variable, and the SSA-ed version before the loop body).
--
-------------------------------------------------------------------------------------
-- getLoopPhis :: SsaEnv r -> Statement (AnnSSA r) -> SSAM r [(Id SrcSpan, Var r)]
-------------------------------------------------------------------------------------
getLoopPhis g b
  = do  θ     <- getSsaVars
        θ'    <- ssaVars . snd <$> tryAction (ssaStmt g b)
        return $ envToList $ envLefts $ envIntersectWith meet θ θ'
  where
    x `meet` y | x == y    = Right x        -- No operation was performed on this var
               | otherwise = Left  x        -- Φ-vars (in the beginning of the loop)

-------------------------------------------------------------------------------------
ssaForLoop :: (Data r, PPR r)
           => SsaEnv r
           -> AnnSSA r
           -> [VarDecl (AnnSSA r)]
           -> Maybe (Expression (AnnSSA r))
           -> Maybe (Statement (AnnSSA r))
           -> Statement (AnnSSA r)
           -> SSAM r (Bool, Statement (AnnSSA r))
-------------------------------------------------------------------------------------
ssaForLoop g l vds cOpt incExpOpt b =
  do
    (b, sts') <- ssaStmts g sts
    return     $ (b, maybeBlock l sts')
  where
    sts        = [VarDeclStmt l vds, WhileStmt l c bd]
    bd         = maybeBlock bl $ [b] ++ catMaybes [incExpOpt]
    bl         = getAnnotation b
    c          = maybe (BoolLit l True) id cOpt

-------------------------------------------------------------------------------------
ssaForLoopExpr :: (Data r, PPR r)
               => SsaEnv r
               -> AnnSSA r
               -> Expression (AnnSSA r)
               -> Maybe (Expression (AnnSSA r))
               -> Maybe (Statement (AnnSSA r))
               -> Statement (AnnSSA r)
               -> SSAM r (Bool, Statement (AnnSSA r))
-------------------------------------------------------------------------------------
ssaForLoopExpr g l exp cOpt incExpOpt b =
  do
    l1        <- fr_ l
    (b, sts') <- ssaStmts g [ExprStmt l1 exp, WhileStmt l c bd]
    l2        <- fr_ l
    return     $ (b, maybeBlock l2 sts')
  where
    bd         = maybeBlock bl $ [b] ++ catMaybes [incExpOpt]
    bl         = getAnnotation b
    c          = maybe (BoolLit l True) id cOpt

