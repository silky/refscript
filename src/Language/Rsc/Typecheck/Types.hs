-- | Global type definitions for Refinement Type Checker

{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE IncoherentInstances       #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE TupleSections             #-}
{-# LANGUAGE TypeSynonymInstances      #-}
{-# LANGUAGE UndecidableInstances      #-}

module Language.Rsc.Typecheck.Types (
  -- Export instances of Monoid
    Monoid(..)

  -- * Type operations
  , toType, ofType, rTop, strengthen, toplevel

  , ExprReftable(..)

  -- * Constructing Types
  , mkUnion, mkFun, mkAll, mkAnd, mkAndOpt, mkInitFldTy, mkTCons

  -- * Deconstructing Types
  , bkFun, bkFunNoBinds, bkFuns, bkAll, bkAnd, bkUnion

  , orUndef, padUndefineds

  , rTypeR

  -- Bounded type variables
  , btvToTV, tvToBTV

  -- * Mutability primitives
  , tMU, tUM, tIM, tAF, tRO, trMU, trIM, trAF, trRO
  , isRO, isMU, isIM, isUM, isAF, isUMRef, mutRelated, mutRelatedBVar

  -- * Primitive Types

  --   # Constructors
  , tNum, tBV32, tBool, tString, tTop, tVoid, tErr, tVar, btVar, tUndef, tNull, tBot, tAny

  --   # Tests
  , isTPrim, isTAny, isTTop, isTUndef, isTUnion, isTStr, isTBool, isBvEnum, isTVar, maybeTObj
  , isTNull, isTVoid, isTFun, isArrayType

  --   # Operations
  , orNull

  -- * Refinements
  , fTop

  -- * Type Definitions
  , typeMembers, typeMembersFromList, typesOfTM

  -- * Operator Types
  , infixOpId, prefixOpId, builtinOpId, arrayLitTy, objLitTy, finalizeTy

  -- * Builtin: Binders
  , mkId, argId, argIdInit, mkArgTy, returnTy

  -- * BitVector
  , bitVectorValue

  , eqV

  ) where

import           Control.Applicative         hiding (empty)
import           Data.Default
import qualified Data.List                   as L
import           Data.Maybe                  (fromMaybe, maybeToList)
import           Data.Monoid                 hiding ((<>))
import           Data.Typeable               ()
import qualified Language.Fixpoint.Bitvector as BV
import           Language.Fixpoint.Misc
import           Language.Fixpoint.Names     (symbolString)
import qualified Language.Fixpoint.Types     as F
import           Language.Rsc.AST.Syntax
import qualified Language.Rsc.Core.Env       as E
import           Language.Rsc.Locations
import           Language.Rsc.Misc           (mapFst, mapSnd3)
import           Language.Rsc.Names
import           Language.Rsc.Types
import           Text.Parsec.Pos             (initialPos)

-- import           Debug.Trace (trace)

---------------------------------------------------------------------
-- | Mutability
---------------------------------------------------------------------

mkMut s    = TRef (Gen (mkAbsName [] s) []) fTop
mkRelMut s = TRef (Gen (mkRelName [] s) []) fTop

tMU, tUM, tIM, tRO, tAF :: F.Reftable r => RType r
tMU   = mkMut "Mutable"
tIM   = mkMut "Immutable"
tRO   = mkMut "ReadOnly"
tAF   = mkMut "AssignsFields"
tUM   = mkMut "UniqueMutable"

trMU, trIM, trRO, trAF :: F.Reftable r => RTypeQ RK r
trMU  = mkRelMut "Mutable"
trIM  = mkRelMut "Immutable"
trRO  = mkRelMut "ReadOnly"
trAF  = mkRelMut "AssignsFields"

typeName (Gen (QN _ s) _)  = s

isNamed s t | TRef n _ <- t, typeName n == F.symbol s = True | otherwise = False

isRO  = isNamed "ReadOnly"
isMU  = isNamed "Mutable"
isIM  = isNamed "Immutable"
isUM  = isNamed "UniqueMutable"
isAF  = isNamed "AssignsFields"

isUMRef t | TRef (Gen _ (m:_)) _ <- t, isUM m
          = True
          | otherwise
          = False

mutRelated t = isMU t || isIM t || isUM t || isRO t

mutRelatedBVar (BTV _ _ (Just m)) = mutRelated m
mutRelatedBVar _                  = False


---------------------------------------------------------------------
-- | Refinement manipulation
---------------------------------------------------------------------

-- | "pure" top-refinement
fTop :: (F.Reftable r) => r
fTop = mempty

-- | Stripping out Refinements
toType :: RTypeQ q a -> RTypeQ q ()
toType = fmap (const ())

-- | Adding in Refinements
ofType :: (F.Reftable r) => RTypeQ q () -> RTypeQ q r
ofType = fmap (const fTop)

-- | Top-up refinemnt
rTop = ofType . toType

class ExprReftable a r where
  exprReft  :: a -> r
  uexprReft :: a -> r

instance ExprReftable a () where
  exprReft  _ = ()
  uexprReft _ = ()

instance F.Expression a => ExprReftable a F.Reft where
  exprReft   = F.exprReft
  uexprReft  = F.uexprReft

instance F.Reftable r => ExprReftable BV.Bv r where
  exprReft  = F.ofReft . F.exprReft
  uexprReft = F.ofReft . F.uexprReft

padUndefineds xs yts
  | nyts <= nxs = Just $ yts ++ xundefs
  | otherwise   = Nothing
  where
    nyts        = length yts
    nxs         = length xs
    xundefs     = [B (F.symbol x') tUndef | x' <- snd $ splitAt nyts xs ]

bkFuns :: RTypeQ q r -> Maybe [([BTVarQ q r], [BindQ q r], RTypeQ q r)]
bkFuns = sequence . fmap bkFun . bkAnd

bkFun :: RTypeQ q r -> Maybe ([BTVarQ q r], [BindQ q r], RTypeQ q r)
bkFun t | (αs, t')   <- bkAll t =
  do  (xts, t'')     <- bkArr t'
      return          $ (αs, xts, t'')

bkFunNoBinds :: RTypeQ q r -> Maybe ([BTVarQ q r], [RTypeQ q r], RTypeQ q r)
bkFunNoBinds = fmap (mapSnd3 $ map b_type) . bkFun

mkFun :: F.Reftable r  => ([BTVarQ q r], [BindQ q r], RTypeQ q r) -> RTypeQ q r
mkFun (αs, bs, rt)    = mkAll αs (TFun bs rt fTop)

bkArr :: RTypeQ q r -> Maybe ([BindQ q r], RTypeQ q r)
bkArr (TFun xts t _)  = Just (xts, t)
bkArr _               = Nothing

mkAll αs t            = mkAnd $ go (reverse αs) <$> bkAnd t
  where
    go (x:xs)         = go xs . TAll x
    go []             = id

bkAll :: RTypeQ q r -> ([BTVarQ q r], RTypeQ q r)
bkAll                 = go []
  where
    go αs (TAll α t)  = go (α : αs) t
    go αs t           = (reverse αs, t)

bkAnd :: RTypeQ q r -> [RTypeQ q r]
bkAnd (TAnd ts) = snd <$> ts
bkAnd t         = [t]

mkAnd [t]       = t
mkAnd ts        = TAnd $ zip [0..] ts

mkAndOpt []     = Nothing
mkAndOpt ts     = Just $ mkAnd ts

instance F.Reftable r => Monoid (RTypeQ q r) where
  mempty        = tBot
  mappend t t'  = mkAnd $ bkAnd t ++ bkAnd t'

mkTCons         = (`TObj` fTop)

----------------------------------------------------------------------------------------
mkUnion :: F.Reftable r => [RTypeQ q r] -> RTypeQ q r
----------------------------------------------------------------------------------------
mkUnion [ ] = TPrim TBot fTop
mkUnion [t] = t
mkUnion ts  = flattenUnions $ TOr $ filter (not . isTBot) ts

----------------------------------------------------------------------------------------
bkUnion :: RTypeQ q t -> [RTypeQ q t]
----------------------------------------------------------------------------------------
bkUnion (TOr ts) = concatMap bkUnion ts
bkUnion t        = [t]

----------------------------------------------------------------------------------------
flattenUnions :: RTypeQ q r -> RTypeQ q r
----------------------------------------------------------------------------------------
flattenUnions t@(TOr _) = TOr $ bkUnion t
flattenUnions t         = t

----------------------------------------------------------------------------------------
orUndef :: F.Reftable r => RType r -> RType r
----------------------------------------------------------------------------------------
orUndef t  | any isTUndef ts = t
           | otherwise = mkUnion $ tUndef:ts
  where ts = bkUnion t


----------------------------------------------------------------------------------------
toplevel :: RTypeQ q r -> (r -> r) -> RTypeQ q r
----------------------------------------------------------------------------------------
toplevel (TPrim c r) f   = TPrim c (f r)
toplevel (TVar v r) f    = TVar v (f r)
toplevel (TOr ts)   _    = TOr ts
toplevel (TAnd ts) _     = TAnd ts
toplevel (TRef n r) f    = TRef n (f r)
toplevel (TObj m ms r) f = TObj m ms (f r)
toplevel (TClass n) _    = TClass n
toplevel (TMod n) _      = TMod n
toplevel (TAll b t) _    = TAll b t
toplevel (TFun b t r) f  = TFun b t (f r)
toplevel (TExp e) _      = TExp e


-- | Strengthen the top-level refinement
----------------------------------------------------------------------------------------
strengthen :: F.Reftable r  => RTypeQ q r -> r -> RTypeQ q r
----------------------------------------------------------------------------------------
strengthen (TOr ts) r' = TOr (map (`strengthen` r') ts)
strengthen t        r' = toplevel t (r' `F.meet`)

-- NOTE: r' is the OLD refinement.
--       We want to preserve its VV binder as it "escapes",
--       e.g. function types. Sigh. Should have used a separate function binder.


----------------------------------------------------------------------------------------
-- | Predicates on Types
----------------------------------------------------------------------------------------

isPrim c t | TPrim c' _ <- t, c == c' = True | otherwise = False

isTPrim t  | TPrim _ _ <- t = True | otherwise = False

isTTop    = isPrim TTop
isTUndef  = isPrim TUndefined
isTBot    = isPrim TBot
isTNull   = isPrim TNull
isTAny    = isPrim TAny
isTVoid   = isPrim TVoid
isTStr    = isPrim TString
isTNum    = isPrim TNumber
isTBool   = isPrim TBoolean
isBV32    = isPrim TBV32

isTVar   t | TVar _ _ <- t = True | otherwise = False
isTUnion t | TOr  _   <- t = True | otherwise = False

maybeTObj (TRef _ _)   = True
maybeTObj (TObj _ _ _) = True
maybeTObj (TClass _)   = True
maybeTObj (TMod _ )    = True
maybeTObj (TAll _ t)   = maybeTObj t
maybeTObj (TOr ts)     = any maybeTObj ts
maybeTObj _            = False

isTFun (TFun _ _ _)    = True
isTFun (TAnd ts)       = all isTFun $ snd <$> ts
isTFun (TAll _ t)      = isTFun t
isTFun _               = False

isArrayType t | TRef (Gen x [_,_]) _ <- t
              = F.symbol x == F.symbol "Array"
              | otherwise
              = False

orNull t@(TOr ts) | any isTNull ts = t
                  | otherwise      = TOr $ tNull:ts
orNull t          | isTNull t      = t
                  | otherwise      = TOr [tNull,t]

---------------------------------------------------------------------------------
eqV :: RType r -> RType r -> Bool
---------------------------------------------------------------------------------
TVar (TV s1 _) _ `eqV` TVar (TV s2 _) _ = s1 == s2
_                `eqV` _                = False

----------------------------------------------------------------------------------
rTypeR' :: F.Reftable r => RType r -> Maybe r
----------------------------------------------------------------------------------
rTypeR' (TPrim _ r)  = Just r
rTypeR' (TVar _ r)   = Just r
rTypeR' (TOr _ )     = Just fTop
rTypeR' (TFun _ _ r) = Just r
rTypeR' (TRef _ r)   = Just r
rTypeR' (TObj _ _ r) = Just r
rTypeR' (TClass _)   = Just fTop
rTypeR' (TMod _)     = Just fTop
rTypeR' (TAnd _ )    = Nothing
rTypeR' (TAll _ _)   = Nothing
rTypeR' (TExp _)     = Nothing

----------------------------------------------------------------------------------
rTypeR :: F.Reftable r => RType r -> r
----------------------------------------------------------------------------------
rTypeR t | Just r <- rTypeR' t = r
         | otherwise = errorstar "Unimplemented: rTypeR"

isBvEnum = all hex . map snd . E.envToList . e_mapping
  where
    hex (HexLit _ _ ) = True
    hex _             = False


-----------------------------------------------------------------------
-- | Primitive / Base Types Constructors
-----------------------------------------------------------------------

-----------------------------------------------------------------------
btvToTV :: BTVarQ q r -> TVar
-----------------------------------------------------------------------
btvToTV  (BTV s l _ ) = TV s l

tvToBTV  (TV s l)     = BTV s l Nothing

tVar :: (F.Reftable r) => TVar -> RType r
tVar = (`TVar` fTop)

btVar :: (F.Reftable r) => BTVarQ q r -> RType r
btVar = tVar . btvToTV

tNum, tBV32, tBool, tString, tTop, tVoid, tBot, tUndef, tNull, tAny, tErr :: F.Reftable r => RTypeQ q r
tPrim   = (`TPrim` fTop)
tNum    = tPrim TNumber
tBV32   = tPrim TBV32
tBool   = tPrim TBoolean
tString = tPrim TString
tTop    = tPrim TTop
tVoid   = tPrim TVoid
tBot    = tPrim TBot
tUndef  = tPrim TUndefined
tAny    = tPrim TAny
tNull   = tPrim TNull
tErr    = tVoid


---------------------------------------------------------------------------------
-- | Array literal types
---------------------------------------------------------------------------------

---------------------------------------------------------------------------------
arrayLitTy :: F.Subable (RType r) => Int -> RType r -> RType r
---------------------------------------------------------------------------------
arrayLitTy n (TAll μ (TAll α (TFun [B x t_] t r))) = mkAll [μ,α] $ TFun αs rt r
  where αs       = [B (x_ i) t_ | i <- [1..n]]
        rt       = F.subst1 t (F.symbol $ builtinOpId BINumArgs, F.expr (n::Int))
        xs       = symbolString x
        x_       = F.symbol . (xs ++) . show
arrayLitTy _ _ = error "Bad Type for ArrayLit Constructor"



---------------------------------------------------------------------------------
-- | Object literal types
---------------------------------------------------------------------------------

-- TODO: Avoid capture
---------------------------------------------------------------------------------
freshBTV :: (F.Reftable r, IsLocated l, Show a)
         => l -> F.Symbol -> Maybe (RTypeQ q r) -> a -> (BTVarQ q r, RTypeQ q r)
---------------------------------------------------------------------------------
freshBTV l s b n  = (bv,t)
  where
    i             = F.intSymbol s n
    bv            = BTV i (srcPos l) b
    v             = TV i (srcPos l)
    t             = TVar v fTop

--------------------------------------------------------------------------------------------
objLitTy         :: (F.Reftable r, IsLocated a) => a -> [Prop a] -> RType r
--------------------------------------------------------------------------------------------
objLitTy l ps     = mkFun (avs, bs, rt)
  where
    bs            = [B s (ofType a) | (s,a) <- zip ss ats ]
    rt            = TObj tIM tms fTop
    tms           = typeMembersFromList [ (s, FI Req Final a) | (s, a) <- zip ss ats ]
    (avs, ats)    = unzip $ map (freshBTV l aSym Nothing) [1..length ps]  -- field type vars
    ss            = [F.symbol p | p <- ps]
    mSym          = F.symbol "M"
    aSym          = F.symbol "A"

lenId l           = Id l "length"
argIdInit l       = Id l $ "arguments"
argId l i         = Id l $ "arguments_" ++ show i

instance F.Symbolic (LValue a) where
  symbol (LVar _ x) = F.symbol x
  symbol lv         = F.symbol "DummyLValue"

instance F.Symbolic (Prop a) where
  symbol (PropId _ (Id _ x)) = F.symbol x -- TODO $ "propId_"     ++ x
  symbol (PropString _ s)    = F.symbol $ "propString_" ++ s
  symbol (PropNum _ n)       = F.symbol $ "propNum_"    ++ show n


-- | @argBind@ returns a dummy type binding `arguments :: T `
--   where T is an object literal containing the non-undefined `ts`.
--------------------------------------------------------------------------------------------
mkArgTy :: (F.Reftable r, IsLocated l) => l -> [RType r] -> VarInfo r
--------------------------------------------------------------------------------------------
mkArgTy l ts   = VI Local RdOnly Initialized
               $ immObjectLitTy [pLen] [tLen]
  where
    ts'        = take k ts
    ps'        = PropNum l . toInteger <$> [0 .. k-1]
    pLen       = PropId l $ lenId l
    tLen       = tNum `strengthen` rLen
    rLen       = F.ofReft $ F.uexprReft k
    k          = fromMaybe (length ts) $ L.findIndex isTUndef ts

--------------------------------------------------------------------------------------------
immObjectLitTy :: F.Reftable r => [Prop l] -> [RType r] -> RType r
--------------------------------------------------------------------------------------------
immObjectLitTy ps ts | length ps == length ts
                     = TObj tIM elts fTop
                     | otherwise
                     = error "Mismatched args for immObjectLit"
  where
    elts = typeMembersFromList [ ( F.symbol p
                             , FI Req Final t )
                             | (p,t) <- safeZip "immObjectLitTy" ps ts
                           ]

--------------------------------------------------------------------------------------------
typeMembers :: F.SEnv (TypeMemberQ q r) -> TypeMembersQ q r
--------------------------------------------------------------------------------------------
typeMembers f = TM f mempty Nothing Nothing Nothing Nothing

--------------------------------------------------------------------------------------------
typeMembersFromList :: F.Symbolic s => [(s, TypeMember r)] -> TypeMembers r
--------------------------------------------------------------------------------------------
typeMembersFromList f = TM (F.fromListSEnv $ mapFst F.symbol <$> f)
                           mempty Nothing Nothing Nothing Nothing

--------------------------------------------------------------------------------------------
typesOfTM :: TypeMembers r -> [RType r]
--------------------------------------------------------------------------------------------
typesOfTM (TM m sm c k s n) =
  concatMap typesOfMem (map snd $ F.toListSEnv m ) ++
  concatMap typesOfMem (map snd $ F.toListSEnv sm) ++
  concatMap maybeToList [c, k, s, n]

typesOfMem (FI _ _ t) = [t]
typesOfMem (MI _ mts) = map snd mts

---------------------------------------------------------------------------------
returnTy :: F.Reftable r => RType r -> Bool -> RType r
---------------------------------------------------------------------------------
returnTy t True  = mkFun ([], [B (F.symbol "r") t], tVoid)
returnTy _ False = mkFun ([], [], tVoid)

---------------------------------------------------------------------------------
finalizeTy :: (F.Reftable r, ExprReftable F.Symbol r) => RType r -> RType r
---------------------------------------------------------------------------------
finalizeTy t  | TRef (Gen x (m:ts)) _ <- t, isUM m
              = mkFun ([mOut], [B sx t], TRef (Gen x (tOut:ts)) (uexprReft sx))
              | otherwise
              = mkFun ([mV], [B (F.symbol "x") tV], tV)
  where
    sx        = F.symbol "x_"
    tOut      = tVar $ btvToTV mOut
    mOut      = BTV (F.symbol "N") def Nothing
    tV        = tVar $ btvToTV mV
    mV        = BTV (F.symbol "V") def Nothing

mkInitFldTy t = mkFun ([], [B (F.symbol "f") t], tVoid)


builtinOpId BIUndefined     = builtinId "BIUndefined"
builtinOpId BIBracketRef    = builtinId "BIBracketRef"
builtinOpId BIBracketAssign = builtinId "BIBracketAssign"
builtinOpId BIArrayLit      = builtinId "BIArrayLit"
builtinOpId BIObjectLit     = builtinId "BIObjectLit"
builtinOpId BISetProp       = builtinId "BISetProp"
builtinOpId BIForInKeys     = builtinId "BIForInKeys"
builtinOpId BICtorExit      = builtinId "BICtorExit"
builtinOpId BINumArgs       = builtinId "BINumArgs"
builtinOpId BITruthy        = builtinId "BITruthy"
builtinOpId BICondExpr      = builtinId "BICondExpr"
builtinOpId BICastExpr      = builtinId "BICastExpr"
builtinOpId BISuper         = builtinId "BISuper"
builtinOpId BISuperVar      = builtinId "BISuperVar"
builtinOpId BICtor          = builtinId "BICtor"
builtinOpId BIThis          = mkId "this"

infixOpId OpLT              = builtinId "OpLT"
infixOpId OpLEq             = builtinId "OpLEq"
infixOpId OpGT              = builtinId "OpGT"
infixOpId OpGEq             = builtinId "OpGEq"
infixOpId OpEq              = builtinId "OpEq"
infixOpId OpStrictEq        = builtinId "OpSEq"
infixOpId OpNEq             = builtinId "OpNEq"
infixOpId OpStrictNEq       = builtinId "OpSNEq"
infixOpId OpLAnd            = builtinId "OpLAnd"
infixOpId OpLOr             = builtinId "OpLOr"
infixOpId OpSub             = builtinId "OpSub"
infixOpId OpAdd             = builtinId "OpAdd"
infixOpId OpMul             = builtinId "OpMul"
infixOpId OpDiv             = builtinId "OpDiv"
infixOpId OpMod             = builtinId "OpMod"
infixOpId OpInstanceof      = builtinId "OpInstanceof"
infixOpId OpBOr             = builtinId "OpBOr"
infixOpId OpBXor            = builtinId "OpBXor"
infixOpId OpBAnd            = builtinId "OpBAnd"
infixOpId OpIn              = builtinId "OpIn"
infixOpId OpLShift          = builtinId "OpLShift"
infixOpId OpSpRShift        = builtinId "OpSpRShift"
infixOpId OpZfRShift        = builtinId "OpZfRShift"

prefixOpId PrefixMinus      = builtinId "PrefixMinus"
prefixOpId PrefixPlus       = builtinId "PrefixPlus"
prefixOpId PrefixLNot       = builtinId "PrefixLNot"
prefixOpId PrefixTypeof     = builtinId "PrefixTypeof"
prefixOpId PrefixBNot       = builtinId "PrefixBNot"
prefixOpId o                = errorstar $ "prefixOpId: Cannot handle: " ++ show o

mkId      = Id (initialPos "")
builtinId = mkId . ("builtin_" ++)


-- | BitVectors

bitVectorValue ('0':x) = Just $ exprReft $ BV.Bv BV.S32  $ "#" ++ x
bitVectorValue _       = Nothing
