{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE LambdaCase                #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE TupleSections             #-}
{-# LANGUAGE FlexibleContexts          #-}

module Language.Nano.SSA.SSA (ssaTransform) where

import           Control.Arrow                           (first, second, (***))
-- import           Control.Applicative                     ((<$>), (<*>))
import           Control.Monad
import           Data.Default
import           Data.Data
import           Data.Maybe                              (catMaybes)
import qualified Data.List                               as L
import qualified Data.IntSet                             as I
import qualified Data.IntMap.Strict                      as IM
import qualified Data.HashSet                            as S
import           Data.Typeable                           ()

import           Language.Nano.Syntax
import           Language.Nano.Syntax.Annotations
import           Language.Nano.Syntax.PrettyPrint

import qualified Language.Fixpoint.Types.Errors                as E
import           Language.Fixpoint.Misc
import qualified Language.Fixpoint.Types                 as F
import           Language.Fixpoint.Types.Names                 (symbolString)

import           Language.Nano.Annots
import           Language.Nano.Env
import           Language.Nano.Errors
import           Language.Nano.Locations
import           Language.Nano.Names
import           Language.Nano.Misc
import           Language.Nano.Program
import           Language.Nano.Types
import           Language.Nano.Typecheck.Resolve
import           Language.Nano.Typecheck.Types
import           Language.Nano.SSA.SSAMonad
import           Language.Nano.Visitor

-- import           Debug.Trace                        hiding (traceShow)

-- FIXME : SSA needs a proper environment like TC an Liquid

----------------------------------------------------------------------------------
ssaTransform :: (PP r, F.Reftable r, Data r)
             => NanoBareR r -> IO (Either (F.FixResult E.Error) (NanoSSAR r))
----------------------------------------------------------------------------------
ssaTransform p = return . execute p . ssaNano $ p

-- | `ssaNano` Perfroms SSA transformation of the input program. The output
-- program is patched (annotated per AST) with information about:
-- * SSA-phi nodes
-- * Spec annotations (functions, global variable declarations)
-- * Type annotations (variable declarations (?), class elements)
----------------------------------------------------------------------------------
ssaNano :: Data r => NanoBareR r -> SSAM r (NanoSSAR r)
----------------------------------------------------------------------------------
ssaNano p@(Nano { code = Src fs })
  = do  setGlobs $ allGlobs
        setMeas  $ S.fromList $ F.symbol <$> envIds (consts p)
        withAsgnEnv (varsInScope fs) $
          do  (_,fs')  <- ssaStmts fs
              ssaAnns  <- getAnns
              ast_cnt  <- getAstCount
              return    $ p { code   = Src $ (patch ssaAnns <$>) <$> fs'
                            , max_id = ast_cnt }
    where
      allGlobs          = I.fromList $ getAnnotation <$> fmap ann_id <$> writeGlobalVars fs
      patch ms (Ann i l fs) = Ann i l (fs ++ IM.findWithDefault [] i ms)


----------------------------------------------------------------------------------
varsInScope :: Data r => [Statement (AnnSSA r)] -> Env Assignability
----------------------------------------------------------------------------------
varsInScope s = envFromList' [ (x,a) | (x,_,_,a,_) <- hoistBindings s ]


-- Assignability ::= ReadOnly | ImportDecl | WriteLocal | ForeignLocal | WriteGlobal | ReturnVar
--
-- γOuter : vars from outer scope
-- γScope  : vars defined in current scope
-- arg  : `arguments` variable
-- xs   : formal parameters
--
mergeFunAsgn γOuter γScope arg xs
    = formals `mappend` γScope `mappend` foreignLocal `mappend` γScope
    -- RHS overwrites
  where
    foreignLocal = envFromList [ (x,ForeignLocal) | (x,WriteLocal) <- envToList γOuter ]
    formals      = envFromList' $ (arg,ReadOnly) : map (,WriteLocal) xs

mergeModuleASgn γOuter γScope
    = γScope `mappend` foreignLocal `mappend` γOuter
    -- RHS overwrites
  where
    foreignLocal = envFromList [ (x,ForeignLocal) | (x,WriteLocal) <- envToList γOuter ]


-------------------------------------------------------------------------------------
ssaFun :: Data r => AnnSSA r -> [Var r] -> [Statement (AnnSSA r)] -> SSAM r [Statement (AnnSSA r)]
-------------------------------------------------------------------------------------
ssaFun l xs body
  = do  γ0         <- getSsaEnv
        arg        <- argId    <$> freshenAnn l
        ret        <- returnId <$> freshenAnn l
        (γ,αs)     <- (,)      <$> getSsaEnv <*> getAsgn
        -- Extend SsaEnv with formal binders
        setSsaEnv   $ extSsaEnv (arg:ret:xs) γ
        (_, body') <- withAsgnEnv (mergeFunAsgn αs (varsInScope body) arg xs) $ ssaStmts body
        -- Restore Outer SsaEnv
        setSsaEnv   $ γ0
        return      $ body'

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

-------------------------------------------------------------------------------------
ssaStmts :: Data r => [Statement (AnnSSA r)] -> SSAM r (Bool, [Statement (AnnSSA r)])
-------------------------------------------------------------------------------------------
ssaStmts ss = second flattenBlock <$> ssaSeq ssaStmt ss


-----------------------------------------------------------------------------------
ssaStmt :: Data r => Statement (AnnSSA r) -> SSAM r (Bool, Statement (AnnSSA r))
-------------------------------------------------------------------------------------
-- skip
ssaStmt s@(EmptyStmt _)
  = return (True, s)

-- declare function foo(...): T;
ssaStmt s@(FuncAmbDecl _ _ _)
  = return (True, s)

ssaStmt s@(FuncOverload _ _ _)
  = return (True, s)

-- interface IA<V> extends IB<T> { ... }
ssaStmt s@(IfaceStmt _ _)
  = return (True, s)

-- x = e
ssaStmt (ExprStmt l1 (AssignExpr l2 OpAssign (LVar l3 v) e)) = do
    let x        = Id l3 v
    (s, x', e') <- ssaAsgn l2 x e
    return         (True, prefixStmt l1 s $ ssaAsgnStmt l1 l2 x x' e')

-- e
ssaStmt (ExprStmt l e) = do
    (s, e') <- ssaExpr e
    return (True, prefixStmt l s $ ExprStmt l e')

-- s1;s2;...;sn
ssaStmt (BlockStmt l stmts) = do
    (b, stmts') <- ssaStmts stmts
    return (b,  BlockStmt l $ flattenBlock stmts')

-- if b { s1 }
ssaStmt (IfSingleStmt l b s)
  = ssaStmt (IfStmt l b s (EmptyStmt l))

-- if b { s1 } else { s2 }
ssaStmt (IfStmt l e s1 s2)
  = do  (se, e')     <- ssaExpr e
        θ            <- getSsaEnv
        φ            <- getSsaEnvGlob
        (θ1, s1')    <- ssaWith θ φ ssaStmt s1
        (θ2, s2')    <- ssaWith θ φ ssaStmt s2
        (phis, θ', φ1, φ2) <- envJoin l θ1 θ2
        case θ' of
          Just θ''   -> do  setSsaEnv     $ θ''
                            latest       <- catMaybes <$> mapM findSsaEnv phis
                            new          <- mapM (updSsaEnv l) phis
                            addAnn l      $ PhiPost $ zip3 phis latest new
                            let stmt'     = prefixStmt l se
                                          $ IfStmt l e' (splice s1' φ1) (splice s2' φ2)
                            return        $ (True,  stmt')
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
ssaStmt (WhileStmt l cnd body)
  = do  (xs, x0s)         <- unzip . map (\(x, (SI xo,_)) -> (x, xo)) <$> getLoopPhis body
        xs'               <- mapM freshenIdSSA xs
        as                <- mapM getAssignability xs'
        let (l1s, l0s,_)  = unzip3 $ filter ((== WriteLocal) . thd3) (zip3 xs' x0s as)
        --
        -- SSA only the WriteLocal variables - globals will remain the same.
        --
        l1s'              <- mapM (updSsaEnv l) l1s
        θ1                <- getSsaEnv
        (sc, cnd')        <- ssaExpr cnd
        when (not $ null sc) (ssaError $ errorUpdateInExpr (srcPos l) cnd)
        (t, body')        <- ssaStmt body
        θ2                <- getSsaEnv
        --
        -- SSA only the WriteLocal variables - globals will remain the same.
        --
        let l2s            = [ x2 | (Just (SI x2), WriteLocal) <- first (`envFindTy` θ2) <$> zip xs as ]
        addAnn l           $ PhiVar l1s'
        setSsaEnv          $ θ1
        l'                <- freshenAnn l
        let body''         = body' `splice` asgn l' (mkNextId <$> l1s') l2s
        l''               <- freshenAnn l
        return             $ (t, asgn l'' l1s' l0s `presplice` WhileStmt l cnd' body'')
    where
        asgn _  [] _       = Nothing
        asgn l' ls rs      = Just $ BlockStmt l' $ zipWith (mkPhiAsgn l') ls rs

ssaStmt (ForStmt _  NoInit _ _ _ )     =
    errorstar "unimplemented: ssaStmt-for-01"

ssaStmt (ForStmt l v cOpt (Just (UnaryAssignExpr l1 o lv)) b) =
    ssaStmt (ForStmt l v cOpt (Just $ AssignExpr l1 (op o) lv (IntLit l1 1)) b)
  where
    op PrefixInc   = OpAssignAdd
    op PrefixDec   = OpAssignSub
    op PostfixInc  = OpAssignAdd
    op PostfixDec  = OpAssignSub

ssaStmt (ForStmt l (VarInit vds) cOpt (Just e@(AssignExpr l1 _ _ _)) b) =
    ssaForLoop l vds cOpt (Just $ ExprStmt l1 (expand e)) b
  where
    expand (AssignExpr l1 o lv e) = AssignExpr l1 OpAssign lv (infOp o l1 lv e)
    expand _ = errorstar "unimplemented: expand assignExpr"

ssaStmt (ForStmt l (VarInit vds) cOpt (Just i) b) =
    ssaForLoop l vds cOpt (Just $ ExprStmt (getAnnotation i) i) b

ssaStmt (ForStmt l (VarInit vds) cOpt Nothing  b) =
    ssaForLoop l vds cOpt Nothing b


ssaStmt (ForStmt l (ExprInit ei) cOpt (Just e@(AssignExpr l1 _ _ _)) b) =
    ssaForLoopExpr l ei cOpt (Just $ ExprStmt l1 (expand e)) b
  where
    expand (AssignExpr l1 o lv e) = AssignExpr l1 OpAssign lv (infOp o l1 lv e)
    expand _ = errorstar "unimplemented: expand assignExpr"

ssaStmt (ForStmt l (ExprInit e) cOpt (Just i) b) =
    ssaForLoopExpr l e cOpt (Just $ ExprStmt (getAnnotation i) i) b

ssaStmt (ForStmt l (ExprInit e) cOpt Nothing  b) =
    ssaForLoopExpr l e cOpt Nothing b


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

ssaStmt (ForInStmt l (ForInVar v) e b) =
    do  init_  <- initArr
        for_   <- forStmt
        ssaStmt $ BlockStmt l [init_, for_]
  where
    fr          = fr_ l
    biForInKeys = return $ builtinId "BIForInKeys"

    initArr     = vStmt        $  VarDecl <$> fr
                                          <*> keysArr
                                          <*> justM (CallExpr <$> fr
                                                              <*> (VarRef <$> fr <*> biForInKeys)
                                                              <*> (return [e]))
    initIdx     = VarDecl     <$> fr
                              <*> keysIdx
                              <*> (Just      <$> (IntLit  <$> fr <*> return 0))
    condition   = Just        <$> (InfixExpr <$> fr
                                             <*> return OpLT
                                             <*> (VarRef  <$> fr <*> keysIdx)
                                             <*> (DotRef  <$> fr
                                                          <*> (VarRef <$> fr <*> keysArr)
                                             <*> (Id      <$> fr
                                                          <*> return "length")))
    increment   = Just        <$> (UnaryAssignExpr
                                             <$> fr
                                             <*> return PostfixInc
                                             <*> (LVar    <$> fr
                                                          <*> (unId <$> keysIdx)))
    accessKeys  = vStmt        $   VarDecl <$> fr
                                           <*> return v
                                           <*> justM (BracketRef <$> fr
                                                                 <*> (VarRef <$> fr <*> keysArr)
                                                                 <*> (VarRef <$> fr <*> keysIdx))
    forStmt     = ForStmt     <$> fr
                              <*> (VarInit <$> single <$> initIdx)
                              <*> condition
                              <*> increment
                              <*> (BlockStmt <$> fr
                                             <*> ( (:[b]) <$> accessKeys))

    vStmt v     = VarDeclStmt <$> fr <*> (single <$> v)

    keysArr     = return $ mkKeysId    v
    keysIdx     = return $ mkKeysIdxId v

    mkId s      = Id (Ann def def def) s
    builtinId s = mkId ("builtin_" ++ s)



-- var x1 [ = e1 ]; ... ; var xn [= en];
ssaStmt (VarDeclStmt l ds) = do
    stvds' <- mapM ssaVarDecl ds
    return    (True, mkStmt $ foldr crunch ([], []) stvds')
  where
    crunch ([], d) (ds, ss') = (d:ds, ss')
    crunch (ss, d) (ds, ss') = ([]  , mkStmts l ss (d:ds) ss')
    mkStmts l ss ds ss'      = ss ++ VarDeclStmt l ds : ss'
    mkStmt (ds', [] )        = VarDeclStmt l ds'
    mkStmt (ds', ss')        = BlockStmt l $ mkStmts l [] ds' ss'

-- return e
ssaStmt s@(ReturnStmt _ Nothing)
  = return (False, s)

-- return e
ssaStmt (ReturnStmt l (Just e)) = do
    (s, e') <- ssaExpr e
    return (False, prefixStmt l s $ ReturnStmt l (Just e'))

-- throw e
ssaStmt (ThrowStmt l e) = do
    (s, e') <- ssaExpr e
    return (False, prefixStmt l s $ ThrowStmt l e')


-- function f(...){ s }
ssaStmt (FunctionStmt l f xs bd)
  = (True,) <$> FunctionStmt l f xs <$> (ssaFun l xs bd)

-- switch (e) { ... }
ssaStmt (SwitchStmt l e xs)
  = do
      id <- updSsaEnv (an e) (Id (an e) "__switchVar")
      let go (l, e, s) i = IfStmt (an s) (InfixExpr l OpStrictEq (VarRef l id) e) s i
      second (BlockStmt l) <$> ssaStmts
        [ VarDeclStmt (an e) [VarDecl (an e) id (Just e)], foldr go z sss ]
  where
      an                   = getAnnotation
      sss                  = [ (l, e, BlockStmt l $ remBr ss) | CaseClause l e ss <- xs ]
      z                    = headWithDefault (EmptyStmt l) [BlockStmt l $ remBr ss | CaseDefault l ss <- xs]

      remBr                = filter (not . isBr) . flattenBlock
      isBr (BreakStmt _ _) = True
      isBr _               = False
      headWithDefault a [] = a
      headWithDefault _ xs = head xs

-- class A extends B implements I,J,... { ... }
--
--  FIXME: fix env here.
--
ssaStmt (ClassStmt l n e is bd)
  = (True,) <$> (ClassStmt l n e is <$> withinClass n (mapM ssaClassElt bd))

ssaStmt (ModuleStmt l n body)
  = do  (γ,αs) <- (,) <$> getSsaEnv <*> getAsgn
        withAsgnEnv (mergeModuleASgn αs (varsInScope body)) $
          do  (_, body') <- withinModule n $ ssaStmts body
              setSsaEnv γ
              return      $ (True, ModuleStmt l n body')
  where

ssaStmt (EnumStmt l n es)
  = return (True, EnumStmt l n es)

-- OTHER (Not handled)
ssaStmt s
  = convertError "ssaStmt" s


ssaAsgnStmt l1 l2 x@(Id l3 v) x' e'
  | x == x'   = ExprStmt l1    (AssignExpr l2 OpAssign (LVar l3 v) e')
  | otherwise = VarDeclStmt l1 [VarDecl l2 x' (Just e')]

-- | Freshen annotation shortcut
--
fr_                   = freshenAnn

-------------------------------------------------------------------------------------
ctorVisitor :: Data r => [Id (AnnSSA r)] -> VisitorM (SSAM r) () () (AnnSSA r)
-------------------------------------------------------------------------------------
ctorVisitor ms            = defaultVisitor { endStmt = es } { endExpr = ee }
                                           { mStmt   = ts } { mExpr   = te }
  where
    es FunctionStmt{}     = True
    es _                  = False
    ee FuncExpr{}         = True
    ee _                  = False

    te (AssignExpr la OpAssign (LDot ld (ThisRef _) s) e)
                          = AssignExpr <$> fr_ la
                                       <*> return OpAssign
                                       <*> (LVar <$> fr_ ld <*> return (mkCtorStr s))
                                       <*> return e
    te lv                 = return lv

    ts (ExprStmt _ (CallExpr l (SuperRef _) es))
      = do  parent  <- par      <$> getProgram <*> getCurrentClass
            flds    <- maybe [] <$> (onlyInheritedFields InstanceMember <$> getProgram)
                                <*> getCurrentClass
            BlockStmt <$> fr_ l
                      <*>  ((:) <$> superVS parent <*> mapM asgnS flds)
      where
        fr      = fr_ l
        par p c   | Just n                    <- c,
                    Just (ID _ _ _ ([(QN _ _ path name ,_)],_) _ ) <- resolveTypeInPgm p n
                  = case path of
                      []     -> VarRef <$> fr <*> (Id <$> fr <*> return (symbolString name))
                      (y:ys) -> do  init <- VarRef <$> fr <*> (Id <$> fr <*> return (symbolString y))
                                    foldM (\e p -> DotRef <$> fr <*> return e
                                                          <*> (Id <$> fr <*> return (symbolString p))) init (ys ++ [name])
                  | otherwise = ssaError $ bugSuperWithNoParent (srcPos l)
        superVS n = VarDeclStmt <$> fr <*> (single <$> superVD n)
        superVD n = VarDecl  <$> fr
                             <*> freshenIdSSA (builtinOpId BISuperVar)
                             <*> justM (NewExpr <$> fr <*> n <*> return es)
        asgnS x = ExprStmt   <$> fr <*> asgnE x
        asgnE x = AssignExpr <$> fr
                             <*> return OpAssign
                             <*> (LDot <$> fr
                                       <*> (ThisRef <$> fr)
                                       <*> return (symbolString x))
                             <*> (DotRef <$> fr
                                         <*> (VarRef <$> fr
                                                     <*> freshenIdSSA (builtinOpId BISuperVar))
                                         <*> (Id <$> fr
                                                 <*> return (symbolString x)))

    ts r@(ReturnStmt l _) = BlockStmt <$> fr_ l <*> ((:[r]) <$> ctorExit l ms)
    ts r                  = return $ r

ctorExit l ms
  = do  m     <- VarRef <$> fr <*> freshenIdSSA (builtinOpId BICtorExit)
        es    <- mapM ((VarRef <$> fr <*>) . return . mkCtorId l) ms
        ReturnStmt <$> fr <*> justM (CallExpr <$> fr <*> return m <*> return es)
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
--    var _ctor_x_0 = 1;
--    var _ctor_y_1 = "string"
--
--    if () { _ctor_x_2 = 2; }
--    // _ctor_x_3 = φ(_ctor_x_2,_ctor_x_0);
--
--    return _ctor_exit(_ctor_x_3,_ctor_y_1);
--
--  }
--
-------------------------------------------------------------------------------------
ssaClassElt :: Data r => ClassElt (AnnSSA r) -> SSAM r (ClassElt (AnnSSA r))
-------------------------------------------------------------------------------------
ssaClassElt (Constructor l xs bd)
  = do  (γ,αs)     <- (,)      <$> getSsaEnv <*> getAsgn
        arg        <- argId <$> freshenAnn l
        -- Extend SsaEnv with formal binders
        setSsaEnv   $ extSsaEnv (arg:xs) γ
        withAsgnEnv (mergeFunAsgn αs (varsInScope bd) arg xs) $
          do  setSsaEnv  $ extSsaEnv (arg:xs) γ
              fs        <- mapM symToVar =<< allFlds
              (_, bd')  <- ssaStmts =<< (++) <$> bdM fs <*> exitM fs
              setSsaEnv  $ γ
              return     $ Constructor l xs bd'
  where
    symToVar    = freshenIdSSA . mkId . symbolString
    allFlds     = L.sort <$> (maybe [] <$> (fieldSymbols InstanceMember <$> getProgram)
                                       <*> getCurrentClass)
    bdM fs      = visitStmtsT (ctorVisitor fs) () bd
    exitM  fs   = single <$> ctorExit l fs

-- | Initilization expression for instance variables is moved to the beginning
--   of the constructor.
ssaClassElt (MemberVarDecl l False x _) = return $ MemberVarDecl l False x Nothing

ssaClassElt (MemberVarDecl l True x (Just e))
  = do z <- ssaExpr e
       case z of
         ([], e') -> return $ MemberVarDecl l True x (Just e')
         _        -> ssaError $ errorEffectInFieldDef (srcPos l)

ssaClassElt (MemberVarDecl l True x Nothing)
  = ssaError $ errorUninitStatFld (srcPos l) x

ssaClassElt (MemberMethDef l s e xs body)
  = MemberMethDef l s e xs <$> ssaFun l xs body

ssaClassElt m@(MemberMethDecl _ _ _ _ ) = return m

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
splice s z = splice_ (getAnnotation s) (Just s) z

splice_ l Nothing Nothing    = EmptyStmt l
splice_ _ (Just s) Nothing   = s
splice_ _ Nothing (Just s)   = s
splice_ _ (Just s) (Just s') = seqStmt (getAnnotation s) s s'


seqStmt _ (BlockStmt l s) (BlockStmt _ s') = BlockStmt l (s ++ s')
seqStmt l s s'                             = BlockStmt l [s, s']

-------------------------------------------------------------------------------------
prefixStmt :: a -> [Statement a] -> Statement a -> Statement a
-------------------------------------------------------------------------------------
prefixStmt _ [] s = s
prefixStmt l ss s = BlockStmt l $ flattenBlock $ ss ++ [s]

-------------------------------------------------------------------------------------
flattenBlock :: [Statement t] -> [Statement t]
-------------------------------------------------------------------------------------
flattenBlock = concatMap f
  where
    f (BlockStmt _ ss) = ss
    f s                = [s ]

-------------------------------------------------------------------------------------
ssaWith :: SsaEnv r         -- Local
        -> SsaEnv r         -- Global
        -> (a -> SSAM r (Bool, b))
        -> a
        -> SSAM r (Maybe (SsaEnv r, SsaEnv r), b)
-------------------------------------------------------------------------------------
ssaWith θ φ f x = do
  setSsaEnv θ
  setSsaEnvGlob φ
  (b, x') <- f x
  (, x')  <$> if b then justM ((,) <$> getSsaEnv <*> getSsaEnvGlob)
                   else return Nothing

-------------------------------------------------------------------------------------
ssaExpr ::  Data r => Expression (AnnSSA r) -> SSAM r ([Statement (AnnSSA r)], Expression (AnnSSA r))
-------------------------------------------------------------------------------------

ssaExpr e@(IntLit _ _)
  = return ([], e)

ssaExpr e@(HexLit _ _)
  = return ([], e)

ssaExpr e@(BoolLit _ _)
  = return ([], e)

ssaExpr e@(StringLit _ _)
  = return ([], e)

ssaExpr e@(NullLit _)
  = return ([], e)

ssaExpr e@(ThisRef _)
  = return ([], e)

ssaExpr e@(SuperRef _)
  = return ([], e)

ssaExpr   (ArrayLit l es)
  = ssaExprs (ArrayLit l) es

ssaExpr (VarRef l x)
  = ([],) <$> ssaVarRef l x

ssaExpr (CondExpr l c e1 e2)
  = do (sc, c') <- ssaExpr c
       θ        <- getSsaEnv
       φ        <- getSsaEnvGlob
       e1'      <- ssaPureExprWith θ φ e1
       e2'      <- ssaPureExprWith θ φ e2
       return (sc, CondExpr l c' e1' e2')

ssaExpr (PrefixExpr l o e)
  = ssaExpr1 (PrefixExpr l o) e

ssaExpr (InfixExpr l OpLOr e1 e2)
  = do  l' <- freshenAnn l
        vid <- Id <$> freshenAnn l <*> (return $ "__InfixExpr_OpLOr_" ++ show (ann_id l'))
        vr  <- VarRef <$> freshenAnn l <*> return vid
        vd  <- VarDecl <$> freshenAnn l <*> return vid <*> return (Just e1)
        vs  <- VarDeclStmt <$> freshenAnn l <*> return [vd]
        (_, vs') <- ssaStmt vs
        (ss,e') <- ssaExpr (CondExpr l vr vr e2)
        return  $ (vs':ss, e')

ssaExpr (InfixExpr l o e1 e2)
  = ssaExpr2 (InfixExpr l o) e1 e2

ssaExpr e@(CallExpr _ (SuperRef _) _)
  = ssaError $ bugSuperNotHandled (srcPos e) e

ssaExpr (CallExpr l e es)
  = ssaExprs (\es' -> CallExpr l (head es') (tail es')) (e : es)

ssaExpr (ObjectLit l ps)
  = ssaExprs (ObjectLit l . zip fs) es
  where
    (fs, es) = unzip ps

ssaExpr (DotRef l e i)
  = ssaExpr1 (\e' -> DotRef l e' i) e

ssaExpr (BracketRef l e1 e2)
  = ssaExpr2 (BracketRef l) e1 e2

ssaExpr (NewExpr l e es)
  = ssaExprs(\es' -> NewExpr l (head es') (tail es')) (e:es)

ssaExpr (Cast l e)
  = ssaExpr1 (Cast l) e

ssaExpr (FuncExpr l fo xs bd)
  = ([],) . FuncExpr l fo xs <$> ssaFun l xs bd

-- x = e
ssaExpr (AssignExpr l OpAssign (LVar lx v) e)
  = ssaAsgnExpr l lx (Id lx v) e

-- e1.f = e2
ssaExpr (AssignExpr l OpAssign (LDot ll e1 f) e2)
  = ssaExpr2 (\e1' e2' -> AssignExpr l OpAssign (LDot ll e1' f) e2') e1 e2

-- e1[e2] = e3
ssaExpr (AssignExpr l OpAssign (LBracket ll e1 e2) e3)
  = ssaExpr3 (\e1' e2' e3' -> AssignExpr l OpAssign (LBracket ll e1' e2') e3') e1 e2 e3

-- lv += e
ssaExpr (AssignExpr l op lv e)
  = ssaExpr (AssignExpr l OpAssign lv rhs)
  where
    rhs = InfixExpr l (assignInfix op) (lvalExp lv) e

-- x++
ssaExpr (UnaryAssignExpr l uop (LVar lv v))
  = do let x           = Id lv v
       xOld           <- ssaVarRef l x
       xNew           <- updSsaEnv l x
       let (eIn, eOut) = unaryExprs l uop xOld (VarRef l xNew)
       return  ([ssaAsgnStmt l lv x xNew eIn], eOut)

-- lv++
ssaExpr (UnaryAssignExpr l uop lv)
  = do lv'   <- ssaLval lv
       let e' = unaryExpr l uop (lvalExp lv')
       return ([], AssignExpr l OpAssign lv' e')

ssaExpr e
  = convertError "ssaExpr" e

ssaAsgnExpr l lx x e
  = do (s, x', e') <- ssaAsgn l x e
       return         (s ++ [ssaAsgnStmt l lx x x' e'], e')

-----------------------------------------------------------------------------
ssaLval    ::  Data r => LValue (AnnSSA r) -> SSAM r (LValue (AnnSSA r))
-----------------------------------------------------------------------------
ssaLval (LVar lv v)
  = do VarRef _ (Id _ v') <- ssaVarRef lv (Id lv v)
       return (LVar lv v')

ssaLval (LDot ll e f)
  = (\e' -> LDot ll e' f) <$> ssaPureExpr e

ssaLval (LBracket ll e1 e2)
  = LBracket ll <$> ssaPureExpr e1 <*> ssaPureExpr e2


--------------------------------------------------------------------------
-- | Helpers for gathering assignments for purifying effectful-expressions
--------------------------------------------------------------------------

ssaExprs f es = (concat *** f) . unzip <$> mapM ssaExpr es

ssaExpr1 = case1 ssaExprs
ssaExpr2 = case2 ssaExprs
ssaExpr3 = case3 ssaExprs
ssaPureExprWith θ φ e = snd <$> ssaWith θ φ (fmap (True,) . ssaPureExpr) e

ssaPureExpr e = do
  (s, e') <- ssaExpr e
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
ssaVarDecl :: Data r
           => VarDecl (AnnSSA r)
           -> SSAM r ([Statement (AnnSSA r)], VarDecl (AnnSSA r))
-------------------------------------------------------------------------------------
ssaVarDecl (VarDecl l x (Just e)) = do
    (s, e') <- ssaExpr e
    x'      <- initSsaEnv l x
    return    (s, VarDecl l x' (Just e'))

ssaVarDecl v@(VarDecl l x Nothing)
  | not $ null [ () | (AmbVarDeclKind,_,_) <- scrapeVarDecl v ]
  = return ([], VarDecl l x Nothing)
  | otherwise
  = ([],) <$> (VarDecl l <$> updSsaEnv l x
                         <*> justM (VarRef <$> fr_ l <*> freshenIdSSA undefinedId))

------------------------------------------------------------------------------------------
ssaVarRef ::  Data r => AnnSSA r -> Id (AnnSSA r) -> SSAM r (Expression (AnnSSA r))
------------------------------------------------------------------------------------------
ssaVarRef l x
  = do getAssignability x >>= \case
         WriteGlobal  -> return e
         ImportDecl   -> return e
         ReadOnly     -> maybe e  (VarRef l) <$> findSsaEnv x
         WriteLocal   -> findSsaEnv x >>= \case
             Just t   -> return   $ VarRef l t
             Nothing  -> return   $ VarRef l x
         ForeignLocal -> ssaError $ errorForeignLocal (srcPos x) x
         ReturnVar    -> ssaError $ errorSSAUnboundId (srcPos x) x
    where
       e = VarRef l x


------------------------------------------------------------------------------------
ssaAsgn :: Data r
        => AnnSSA r
        -> Id (AnnSSA r)
        -> Expression (AnnSSA r)
        -> SSAM r ([Statement (AnnSSA r)], Id (AnnSSA r), Expression (AnnSSA r))
------------------------------------------------------------------------------------
ssaAsgn l x e  = do
    (s, e') <- ssaExpr e
    x'      <- updSsaEnv l x
    return (s, x', e')


-------------------------------------------------------------------------------------
-- envJoin :: Data r => AnnSSA r -> Maybe (SsaEnv r) -> Maybe (SsaEnv r)
--         -> SSAM r ( Maybe (SsaEnv r),
--                     Maybe (Statement (AnnSSA r)),
--                     Maybe (Statement (AnnSSA r)))
-------------------------------------------------------------------------------------
envJoin _ Nothing Nothing     = return ([], Nothing, Nothing, Nothing)
envJoin _ Nothing (Just θ)    = return ([], Just $ fst θ , Nothing, Nothing)
envJoin _ (Just θ) Nothing    = return ([], Just $ fst θ , Nothing, Nothing)
envJoin l (Just θ1) (Just θ2) = envJoin' l θ1 θ2

envJoin' l (θ1,φ1) (θ2,φ2) = do
    setSsaEnv θ'                          -- Keep Common binders
    phis       <- mapM (mapFstM freshenIdSSA) (envToList $ envLefts θ)
    gl_phis    <- mapM (mapFstM freshenIdSSA) (envToList $ envLefts φ)
    stmts      <- forM (phis ++ gl_phis) $ phiAsgn l   -- Adds Phi-Binders, Phi Annots, Return Stmts
    θ''        <- getSsaEnv
    let (s1,s2) = unzip stmts
    return (fst <$> phis, Just θ'', Just $ BlockStmt l s1, Just $ BlockStmt l s2)
  where
    φ           = envIntersectWith meet φ1 φ2
    θ           = envIntersectWith meet θ1 θ2
    θ'          = envRights θ
    meet        = \x1 x2 -> if x1 == x2 then Right x1 else Left (x1, x2)

phiAsgn l (x, (SI x1, SI x2)) = do
    (a,x') <- updSsaEnv' l x                       -- Generate FRESH phi name
    addAnn l (PhiVar [x'])                         -- RECORD x' as PHI-Var at l
    case a of
      WriteLocal -> let s1 = mkPhiAsgn l x' x1 in  -- Create Phi-Assignments
                    let s2 = mkPhiAsgn l x' x2 in  -- for both branches
                    return (s1, s2)
      _          -> return (EmptyStmt def, EmptyStmt def)

mkPhiAsgn :: AnnSSA r -> Id (AnnSSA r) -> Id (AnnSSA r) -> Statement (AnnSSA r)
mkPhiAsgn l x y = VarDeclStmt l [VarDecl l x (Just $ VarRef l y)]


-- Get the phi vars starting from an SSAEnv @θ@ and going through the statement @b@.
-- getLoopPhis :: Statement (AnnSSA r) -> SSAM r [Var r]
getLoopPhis b = do
    θ     <- getSsaEnv
    θ'    <- names <$> snd <$> tryAction (ssaStmt b)
    let xs = envToList (envLefts $ envIntersectWith meet θ θ')
    return xs
  where
    meet x x' = if x == x' then Right x else Left (x, x')


-------------------------------------------------------------------------------------
ssaForLoop :: Data r
           => AnnSSA r
           -> [VarDecl (AnnSSA r)]
           -> Maybe (Expression (AnnSSA r))
           -> Maybe (Statement (AnnSSA r))
           -> Statement (AnnSSA r)
           -> SSAM r (Bool, Statement (AnnSSA r))
-------------------------------------------------------------------------------------
ssaForLoop l vds cOpt incExpOpt b =
  do
    (b, sts') <- ssaStmts sts
    return     $ (b, BlockStmt l sts')
  where
    sts        = [VarDeclStmt l vds, WhileStmt l c bd]
    bd         = BlockStmt bl $ [b] ++ catMaybes [incExpOpt]
    bl         = getAnnotation b
    c          = maybe (BoolLit l True) id cOpt

-------------------------------------------------------------------------------------
ssaForLoopExpr :: Data r
               => AnnSSA r
               -> Expression (AnnSSA r)
               -> Maybe (Expression (AnnSSA r))
               -> Maybe (Statement (AnnSSA r))
               -> Statement (AnnSSA r)
               -> SSAM r (Bool, Statement (AnnSSA r))
-------------------------------------------------------------------------------------
ssaForLoopExpr l exp cOpt incExpOpt b =
  do
    l1        <- fr_ l
    (b, sts') <- ssaStmts [ExprStmt l1 exp, WhileStmt l c bd]
    l2        <- fr_ l
    return     $ (b, BlockStmt l2 sts')
  where
    bd         = BlockStmt bl $ [b] ++ catMaybes [incExpOpt]
    bl         = getAnnotation b
    c          = maybe (BoolLit l True) id cOpt


-- Local Variables:
-- flycheck-disabled-checkers: (haskell-liquid)
-- End:
