-- | Global type definitions for Refinement Type Checker

{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE DeriveFunctor             #-}
{-# LANGUAGE DeriveTraversable         #-}
{-# LANGUAGE DeriveFoldable            #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE TupleSections             #-}
{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE TypeSynonymInstances      #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE OverlappingInstances      #-}
{-# LANGUAGE IncoherentInstances       #-}
{-# LANGUAGE UndecidableInstances      #-}
{-# LANGUAGE NoMonomorphismRestriction #-}

module Language.Nano.Typecheck.Types (

  -- * Type operations
    toType, ofType, rTop, strengthen

  , PPR, ExprReftable(..)

  -- * Predicates on Types
  , isTop, isNull, isVoid, isTNum, isUndef, isUnion, isTString, isTBool

  , isBvEnum

  -- * Primitive Types
  , t_object

  -- * Constructing Types
  , mkUnion, mkUnionR, mkFun, mkAll, mkAnd, mkEltFunTy, mkInitFldTy, flattenUnions, mkTCons

  -- * Deconstructing Types
  , bkFun, bkFunBinds, bkFunNoBinds, bkFuns, bkAll, bkAnd, bkUnion, orUndef, funTys, padUndefineds

  , rUnion, rTypeR, rTypeROpt, setRTypeR

  , renameBinds

  -- * Mutability primitives
  , t_mutable, t_uq_mutable, t_immutable, t_anyMutability, t_inheritedMut, t_readOnly
  , tr_mutable, tr_immutable, tr_anyMutability, tr_inheritedMut, tr_readOnly
  , isMutable, isImmutable, isUniqueMutable, isInheritedMutability

  , finalizeTy

  -- * Primitive Types
  , tInt, tBV32, tBool, tString, tTop, tVoid, tErr, tFunErr, tVar, tUndef, tNull
  , isTVar, isTObj, isExpandable, isPrimitive, isConstr, subtypeable, isTUndef, isTNull, isTVoid
  , isTFun, fTop, orNull, isArr

  -- * Element ops
  , sameBinder, eltType, allEltType, nonConstrElt, {- mutability,-} baseType
  , isMethodSig, isFieldSig, fieldSigs, isStringIndexer, hasStringIndexer, getStringIndexer
  , setThisBinding, remThisBinding, mapElt, mapElt', mapEltM
  , requiredField, optionalField, f_optional, f_required, optionalFieldType, requiredFieldType
  , f_requiredR, f_optionalR

  -- * Operator Types
  , infixOpId
  , prefixOpId
  , builtinOpId
  , arrayLitTy
  , objLitTy
  , setPropTy
  , localTy

  -- * Builtin: Binders
  , mkId, argId, mkArgTy, returnTy

  -- * Symbols
  , ctorSymbol, callSymbol, stringIndexSymbol, numericIndexSymbol

  -- * BitVector
  , bitVectorValue

  ) where

import           Data.Data
import           Data.Default
import           Data.Hashable
import           Data.Either                    (partitionEithers)
import qualified Data.List                      as L
import           Data.Maybe                     (fromMaybe, isJust, fromJust)
import           Data.Monoid                    hiding ((<>))
import qualified Data.Map.Strict                as M
import           Data.Typeable                  ()
import           Language.Nano.Syntax
import           Language.Nano.Syntax.PrettyPrint
import qualified Language.Nano.Env              as E
import           Language.Nano.Misc
import           Language.Nano.Types
import           Language.Nano.Errors
import           Language.Nano.Locations
import           Language.Nano.Names
import           Language.Fixpoint.Types.Names (symbolString)
import qualified Language.Fixpoint.Types        as F
import qualified Language.Fixpoint.Smt.Bitvector    as BV
import           Language.Fixpoint.Misc
import           Language.Fixpoint.Types.Errors
import           Language.Fixpoint.Types.PrettyPrint
import           Text.PrettyPrint.HughesPJ
import           Text.Parsec.Pos                    (initialPos)

import           Control.Applicative            hiding (empty)
import           Control.Exception              (throw)

-- import           Debug.Trace (trace)

type PPR  r = (ExprReftable F.Symbol r, ExprReftable Int r, PP r, F.Reftable r, Data r)

---------------------------------------------------------------------
-- | Primitive Types
---------------------------------------------------------------------

mkPrimTy s m = TRef (QN AK_ (srcPos dummySpan) [] (F.symbol s)) [m] fTop

t_object = mkPrimTy "Object" t_immutable


---------------------------------------------------------------------
-- | Mutability
---------------------------------------------------------------------

mkMut s = TRef (QN AK_ (srcPos dummySpan) [] (F.symbol s)) [] fTop
mkRelMut s = TRef (QN RK_ (srcPos dummySpan) [] (F.symbol s)) [] fTop

instance Default Mutability where
  def = mkMut "Immutable"

t_mutable       = mkMut "Mutable"
t_uq_mutable    = mkMut "UniqueMutable"
t_immutable     = mkMut "Immutable"
t_anyMutability = mkMut "AnyMutability"
t_readOnly      = mkMut "ReadOnly"
t_inheritedMut  = mkMut "InheritedMut"

tr_mutable       = mkRelMut "Mutable"
tr_immutable     = mkRelMut "Immutable"
tr_anyMutability = mkRelMut "AnyMutability"
tr_readOnly      = mkRelMut "ReadOnly"
tr_inheritedMut  = mkRelMut "InheritedMut"


isMutable        (TRef (QN AK_ _ [] s) _ _) = s == F.symbol "Mutable"
isMutable _                                 = False

-- Ideally this would be a AK_ but meh...
isImmutable      (TRef (QN _ _ [] s) _ _) = s == F.symbol "Immutable"
isImmutable _                             = False

isUniqueMutable  (TRef (QN AK_ _ [] s) _ _) = s == F.symbol "UniqueMutable"
isUniqueMutable  (TApp TUn ts _ )           = any isUniqueMutable ts
isUniqueMutable  _                          = False

isInheritedMutability  (TRef (QN _ _ [] s) _ _) = s == F.symbol "InheritedMut"
isInheritedMutability  _                        = False


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


funTys l f xs ft
  = case bkFuns ft of
      Nothing -> Left $ errorNonFunction (srcPos l) f ft
      Just ts ->
        case partitionEithers [funTy l xs t | t <- ts] of
          ([], fts) -> Right $ zip ([0..] :: [Int]) fts
          (_ , _  ) -> Left  $ errorArgMismatch (srcPos l)


funTy l xs (αs, s, yts, t) =
  case padUndefineds xs yts of
    Nothing   -> Left  $ errorArgMismatch (srcPos l)
    Just yts' -> Right $ (αs, s, ts', F.subst su t)
                   where
                    (su, ts') = renameBinds yts' xs

padUndefineds xs yts
  | nyts <= nxs = Just $ yts ++ xundefs
  | otherwise   = Nothing
  where
    nyts        = length yts
    nxs         = length xs
    xundefs     = [B (F.symbol x') tUndef | x' <- snd $ splitAt nyts xs ]

renameBinds yts xs    = (su, [F.subst su ty | B _ ty <- yts])
  where
    su                = F.mkSubst suL
    suL               = safeZipWith "renameBinds" fSub yts xs
    fSub yt x         = (b_sym yt, F.eVar x)


bkFuns :: RTypeQ q r -> Maybe [([TVar], Maybe (RTypeQ q r), [BindQ q r], RTypeQ q r)]
bkFuns = sequence . fmap bkFun . bkAnd

bkFun :: RTypeQ q r -> Maybe ([TVar], Maybe (RTypeQ q r), [BindQ q r], RTypeQ q r)
bkFun t = do let (αs, t')   = bkAll t
             (s, xts, t'') <- bkArr t'
             return           (αs, s, xts, t'')

bkFunBinds :: RTypeQ q r -> Maybe ([TVar], FuncInputs (BindQ q r), RTypeQ q r)
bkFunBinds t = do let (αs, t')   = bkAll t
                  (s, xts, t'') <- bkArr t'
                  return           (αs, FI (B (F.symbol "this") <$> s) xts, t'')


bkFunNoBinds :: RTypeQ q r -> Maybe ([TVar], FuncInputs (RTypeQ q r), RTypeQ q r)
bkFunNoBinds t = do (αs, s, bs, t) <- bkFun t
                    return          $ (αs, FI s (b_type <$> bs), t)

mkFun :: (F.Reftable r) => ([TVar], Maybe (RTypeQ q r), [BindQ q r], RTypeQ q r) -> RTypeQ q r
mkFun ([], s, bs, rt) = TFun s bs rt fTop
mkFun (αs, s, bs, rt) = mkAll αs (TFun s bs rt fTop)

bkArr (TFun s xts t _) = Just (s, xts, t)
bkArr _                = Nothing

mkAll αs t           = mkAnd $ go (reverse αs) <$> bkAnd t
  where
    go (α:αs) t      = go αs (TAll α t)
    go []     t      = t

bkAll                :: RTypeQ q a -> ([TVar], RTypeQ q a)
bkAll t              = go [] t
  where
    go αs (TAll α t) = go (α : αs) t
    go αs t          = (reverse αs, t)

bkAnd                :: RTypeQ q r -> [RTypeQ q r]
bkAnd (TAnd ts)      = ts
bkAnd t              = [t]

mkAnd [t]            = t
mkAnd ts             = TAnd ts

mapAnd f t           = mkAnd $ f <$> bkAnd t

mkTCons m es = TCons m es fTop

----------------------------------------------------------------------------------------
mkUnion :: (F.Reftable r) => [RType r] -> RType r
----------------------------------------------------------------------------------------
mkUnion ts     = mkUnionR ts fTop

----------------------------------------------------------------------------------------
mkUnionR :: (F.Reftable r) => [RType r] -> r -> RType r
----------------------------------------------------------------------------------------
mkUnionR [ ] _ = tVoid
mkUnionR [t] r = t `strengthen` r
mkUnionR ts  r = flattenUnions $ TApp TUn ts r

----------------------------------------------------------------------------------------
bkUnion :: RType r -> [RType r]
----------------------------------------------------------------------------------------
bkUnion (TApp TUn xs _) = xs
bkUnion t               = [t]

----------------------------------------------------------------------------------------
bkUnionR :: F.Reftable r => RType r -> ([RType r], r)
----------------------------------------------------------------------------------------
bkUnionR (TApp TUn xs r) = (xs, r)
bkUnionR t               = ([t], fTop)

----------------------------------------------------------------------------------------
orUndef :: F.Reftable r => RType r -> RType r
----------------------------------------------------------------------------------------
orUndef t | any isUndef ts = t
          | otherwise      = mkUnionR (tUndef:ts) r
  where
    (ts, r) = bkUnionR t


-- | @flattenUnions@: flattens one-level of unions
--
-- FIXME: add check for duplicates in parts of unions
--
----------------------------------------------------------------------------------------
flattenUnions :: F.Reftable r => RTypeQ q r -> RTypeQ q r
----------------------------------------------------------------------------------------
flattenUnions (TApp TUn ts r) = TApp TUn (concatMap go ts) r
  where go (TApp TUn τs r)    = (`strengthen` r) <$> τs
        go t                  = [t]
flattenUnions t               = t



-- | Strengthen the top-level refinement
----------------------------------------------------------------------------------------
strengthen                   :: F.Reftable r => RTypeQ q r -> r -> RTypeQ q r
----------------------------------------------------------------------------------------
strengthen (TApp c ts r) r'  = TApp c ts  $ r' `F.meet` r
strengthen (TRef c ts r) r'  = TRef c ts  $ r' `F.meet` r
strengthen (TCons ts m r) r' = TCons ts m $ r' `F.meet` r
strengthen (TVar α r)    r'  = TVar α     $ r' `F.meet` r
strengthen (TFun a b c r) r' = TFun a b c $ r' `F.meet` r
strengthen t _               = t

-- NOTE: r' is the OLD refinement.
--       We want to preserve its VV binder as it "escapes",
--       e.g. function types. Sigh. Should have used a separate function binder.


-- | Strengthen the refinement of a type @t2@ deeply, using the
-- refinements of an equivalent (having the same raw version)
-- type @t1@.


----------------------------------------------------------------------------------------
-- | Predicates on Types
----------------------------------------------------------------------------------------

-- | Top-level Top (any) check
isTop :: RType r -> Bool
isTop (TApp TTop _ _)   = True
isTop (TApp TUn  ts _ ) = any isTop ts
isTop _                 = False

isUndef :: RType r -> Bool
isUndef (TApp TUndef _ _)   = True
isUndef _                   = False

isNull :: RType r -> Bool
isNull (TApp TNull _ _)   = True
isNull _                  = False

isVoid :: RType r -> Bool
isVoid (TApp TVoid _ _)    = True
isVoid _                   = False

isTObj (TRef _ _ _)        = True
isTObj (TCons _ _ _)       = True
isTObj (TModule _)         = True
isTObj (TClass _ )         = True
isTObj (TEnum _ )          = True
isTObj (TSelf _ )          = True
isTObj _                   = False

isPrimitive v = isUndef v || isNull v || isTString v || isTBool v || isTNum v

isExpandable v = isTObj v || isTNum v || isTBool v || isTString v

isTString (TApp TString _ _) = True
isTString _                  = False

isTBool (TApp TBool _ _)   = True
isTBool _                  = False

isTNum (TApp TInt _ _ )    = True
isTNum _                   = False

isConstr (ConsSig _)  = True
isConstr _            = False

isUnion :: RType r -> Bool
isUnion (TApp TUn _ _) = True           -- top-level union
isUnion _              = False

-- Get the top-level refinement for unions - use Top (True) otherwise
rUnion               :: F.Reftable r => RType r -> r
rUnion (TApp TUn _ r) = r
rUnion _              = fTop

-- Get the top-level refinement
rTypeR               :: F.Reftable r => RType r -> r
rTypeR (TApp _ _ r )  = r
rTypeR (TVar _ r   )  = r
rTypeR (TFun _ _ _ r) = r
rTypeR (TCons _ _ r)  = r
rTypeR (TRef _ _ r)   = r
rTypeR (TModule _  )  = fTop
rTypeR (TEnum _  )    = fTop
rTypeR (TClass _   )  = fTop
rTypeR (TAll _ _   )  = errorstar "Unimplemented: rTypeR - TAll"
rTypeR (TAnd _ )      = errorstar "Unimplemented: rTypeR - TAnd"
rTypeR (TExp _)       = errorstar "Unimplemented: rTypeR - TExp"
rTypeR (TSelf _)      = errorstar "Unimplemented: rTypeR - TSelf"

rTypeROpt               :: F.Reftable r => RType r -> Maybe r
rTypeROpt (TApp _ _ r )  = Just r
rTypeROpt (TVar _ r   )  = Just r
rTypeROpt (TFun _ _ _ r) = Just r
rTypeROpt (TCons _ _ r)  = Just r
rTypeROpt (TRef _ _ r)   = Just r
rTypeROpt _              = Nothing

-- Set the top-level refinement (wherever applies)
setRTypeR :: RType r -> r -> RType r
setRTypeR (TApp c ts _   )  r = TApp c ts r
setRTypeR (TVar v _      )  r = TVar v r
setRTypeR (TFun s xts ot _) r = TFun s xts ot r
setRTypeR (TCons x y _)     r = TCons x y r
setRTypeR (TRef x y _)      r = TRef x y r
setRTypeR t                 _ = t


mapElt f (CallSig t)         = CallSig         $ f t
mapElt f (ConsSig t)         = ConsSig         $ f t
mapElt f (IndexSig x b t)    = IndexSig x b    $ f t
mapElt f (FieldSig x o m t)  = FieldSig x o m  $ f t
mapElt f (MethSig  x t)      = MethSig  x      $ f t

mapElt' f (CallSig t)        = CallSig         $ f t
mapElt' f (ConsSig t)        = ConsSig         $ f t
mapElt' f (IndexSig x b t)   = IndexSig x b    $ f t
mapElt' f (FieldSig x o m t) = FieldSig x (toType $ f $ ofType o) (toType $ f $ ofType m) (f t)
mapElt' f (MethSig  x t)     = MethSig  x      $ f t

mapEltM f (CallSig t)        = CallSig        <$> f t
mapEltM f (ConsSig t)        = ConsSig        <$> f t
mapEltM f (IndexSig i b t)   = IndexSig i b   <$> f t
mapEltM f (FieldSig x o m t) = FieldSig x o m <$> f t
mapEltM f (MethSig  x t)     = MethSig x      <$> f t

nonConstrElt = not . isConstr

isMethodSig MethSig{} = True
isMethodSig _         = False


-- | Optional fields

isFieldSig FieldSig{} = True
isFieldSig _          = False

fieldSigs es          = [ e | e@FieldSig{} <- es ]

hasStringIndexer      = isJust   . L.find isStringIndexer
getStringIndexer      = fromJust . L.find isStringIndexer

isStringIndexer (IndexSig _ i _) = i == StringIndex
isStringIndexer _                = False

optionalFieldType (TRef (QN _ _ [] s) _ _) = s == F.symbol "OptionalField"
optionalFieldType _                        = False

requiredFieldType (TRef (QN _ _ [] s) _ _) = s == F.symbol "RequiredField"
requiredFieldType _                        = False


requiredField (FieldSig _ o _ _) = not $ optionalFieldType o
requiredField _                  = True

optionalField (FieldSig _ o _ _) = optionalFieldType o
optionalField _                  = False

f_optional = TRef (QN AK_ (srcPos dummySpan) [] (F.symbol "OptionalField")) [] fTop
f_required = TRef (QN AK_ (srcPos dummySpan) [] (F.symbol "RequiredField")) [] fTop

f_optionalR = TRef (QN RK_ (srcPos dummySpan) [] (F.symbol "OptionalField")) [] fTop
f_requiredR = TRef (QN RK_ (srcPos dummySpan) [] (F.symbol "RequiredField")) [] fTop

-- Typemembers that take part in subtyping
subtypeable e = not (isConstr e)

setThisBinding m@(MethSig _ t) t' = m { f_type = mapAnd bkTy t }
  where
    bkTy ty | Just (vs,to,bs,ot) <- bkFun ty
            = mkFun (vs, maybe (Just t') Just to, bs, ot)
            | otherwise
            = ty
setThisBinding m _ = m

remThisBinding t | Just ts <- bkFuns t = mkAnd $ mkFun . go <$> ts
                 | otherwise           = t
  where
    go (vs, _, bs, ot) = (vs, Nothing, bs, ot)


instance F.Symbolic IndexKind where
  symbol StringIndex  = stringIndexSymbol
  symbol NumericIndex = numericIndexSymbol

instance F.Symbolic (TypeMemberQ q t) where
  symbol (FieldSig s _ _ _) = s
  symbol (MethSig  s _)     = s
  symbol (ConsSig       _)  = ctorSymbol
  symbol (CallSig       _)  = callSymbol
  symbol (IndexSig _ i _)   = F.symbol i

ctorSymbol         = F.symbol "__constructor__"
callSymbol         = F.symbol "__call__"
stringIndexSymbol  = F.symbol "__string__index__"
numericIndexSymbol = F.symbol "__numeric__index__"


sameBinder (CallSig _)         (CallSig _)         = True
sameBinder (ConsSig _)         (ConsSig _)         = True
sameBinder (IndexSig _ b1 _)   (IndexSig _ b2 _)   = b1 == b2
sameBinder (FieldSig x1 _ _ _) (FieldSig x2 _ _ _) = x1 == x2
sameBinder (MethSig x1 _)      (MethSig x2 _)      = x1 == x2
sameBinder _                 _                     = False

-- mutability :: TypeMember r -> Maybe Mutability
-- mutability (CallSig _)        = Nothing
-- mutability (ConsSig _)        = Nothing
-- mutability (IndexSig _ _ _)   = Nothing
-- mutability (FieldSig _ _ m _) = Just m
-- mutability (MethSig _ m  _)   = Just m

baseType (FieldSig _ _ _ t) = case bkFun t of
                                  Just (_, Just t, _, _) -> Just t
                                  _                      -> Nothing
baseType (MethSig _ t)      = case bkFun t of
                                Just (_, Just t, _, _) -> Just t
                                _                      -> Nothing
baseType _                  = Nothing

eltType (FieldSig _ _ _  t) = t
eltType (MethSig _       t) = t
eltType (ConsSig         t) = t
eltType (CallSig         t) = t
eltType (IndexSig _ _    t) = t

allEltType (FieldSig _ o m t) = [ofType o, ofType m, t]
allEltType (MethSig _      t) = [t]
allEltType (ConsSig        t) = [t]
allEltType (CallSig        t) = [t]
allEltType (IndexSig _ _   t) = [t]


isBvEnum              = all hex . map snd . E.envToList . e_mapping
  where
    hex (HexLit _ _ ) = True
    hex _             = False


----------------------------------------------------------------------------------
-- | Pretty Printer Instances
----------------------------------------------------------------------------------

angles p = char '<' <> p <> char '>'

instance PP Bool where
  pp True   = text "True"
  pp False  = text "False"

instance PP () where
  pp _ = text ""

instance PP a => PP (Maybe a) where
  pp = maybe (text "Nothing") pp

instance PP Char where
  pp = char


instance (PP r, F.Reftable r) => PP (RTypeQ q r) where
  pp (TVar α r)               = F.ppTy r $ (text "#" <> pp α)
  pp (TFun (Just s) xts t _)  = ppArgs parens comma (B (F.symbol "this") s:xts) <+> text "=>" <+> pp t
  pp (TFun _ xts t _)         = ppArgs parens comma xts <+> text "=>" <+> pp t
  pp t@(TAll _ _)             = text "∀" <+> ppArgs id space αs <> text "." <+> pp t' where (αs, t') = bkAll t
  pp (TAnd ts)                = vcat [text "/\\" <+> pp t | t <- ts]
  pp (TExp e)                 = pprint e
  pp (TApp TUn ts r)          = F.ppTy r $ ppArgs id (text " +") ts
  pp t@(TRef _ [] _)          | Just m <- mutSym t = text m
  pp (TRef x ts r)            = F.ppTy r $ pp x <>         ppArgs angles comma ts
  pp (TSelf m)                = text "TSelf" <> text "_" <> ppMut m
  pp (TApp c [] r)            = F.ppTy r $ pp c
  pp (TApp c ts r)            = F.ppTy r $ parens (pp c <+> ppArgs id space ts)
  pp (TCons m bs r)           | M.size bs < 3
                              = F.ppTy r $ ppMut m <+> braces (intersperse semi $ ppHMap pp bs)
                              | otherwise
                              = F.ppTy r $ ppMut m <+> lbrace $+$ nest 2 (vcat $ ppHMap pp bs) $+$ rbrace
  pp (TModule s  )            = text "module" <+> pp s
  pp (TClass c   )            = text "typeof" <+> pp c
  pp (TEnum c   )             = text "enum" <+> pp c

ppHMap p = map (p . snd) . M.toList

instance PP t => PP (FuncInputs t) where
  pp (FI (Just a) []) = parens $ brackets (pp "this" <> colon <+> pp a)
  pp (FI (Just a) as) = parens $ brackets (pp "this" <> colon <+> pp a) <> comma <+> ppArgs id comma as
  pp (FI Nothing  as) = ppArgs parens comma as

instance PP TVar where
  pp     = pprint . F.symbol

instance PP TCon where
  pp TInt      = text "number"
  pp TBV32     = text "bitvector"
  pp TBool     = text "boolean"
  pp TString   = text "string"
  pp TVoid     = text "void"
  pp TTop      = text "top"
  pp TUn       = text "union:"
  pp TNull     = text "null"
  pp TUndef    = text "undefined"
  pp TFPBool   = text "bool"

instance Hashable TCon where
  hashWithSalt s TInt         = hashWithSalt s (0 :: Int)
  hashWithSalt s TBool        = hashWithSalt s (1 :: Int)
  hashWithSalt s TString      = hashWithSalt s (2 :: Int)
  hashWithSalt s TVoid        = hashWithSalt s (3 :: Int)
  hashWithSalt s TTop         = hashWithSalt s (4 :: Int)
  hashWithSalt s TUn          = hashWithSalt s (5 :: Int)
  hashWithSalt s TNull        = hashWithSalt s (6 :: Int)
  hashWithSalt s TUndef       = hashWithSalt s (7 :: Int)
  hashWithSalt s TFPBool      = hashWithSalt s (8 :: Int)
  hashWithSalt s TBV32        = hashWithSalt s (9 :: Int)

instance (PP r, F.Reftable r) => PP (BindQ q r) where
  pp (B x t)          = pp x <> colon <> pp t

instance (PP s, PP t) => PP (M.Map s t) where
  pp m = vcat $ pp <$> M.toList m


instance PP Visibility where
  pp Local = text ""
  pp Exported = text "exported "

instance PP StaticKind where
  pp StaticMember   = text "static"
  pp InstanceMember = text ""

instance PP Assignability where
  pp ReadOnly     = text "ReadOnly"
  pp WriteLocal   = text "WriteLocal"
  pp ForeignLocal = text "ForeignLocal"
  pp WriteGlobal  = text "WriteGlobal"
  pp ImportDecl   = text "ImportDecl"
  pp ReturnVar    = text "ReturnVar"

instance PP IfaceKind where
  pp ClassKind      = pp "class"
  pp InterfaceKind  = pp "interface"

instance (PP r, F.Reftable r) => PP (IfaceDef r) where
  pp (ID nm c vs h ts) =
        pp c
    <+> ppBase (nm, vs)
    <+> ppHeritage h
    <+> lbrace $+$ nest 2 (vcat $ ppHMap pp ts) $+$ rbrace

ppHeritage (es,is) = ppHeritage1 "extends" es <+> ppHeritage1 "implements" is

ppHeritage1 _ []   = text""
ppHeritage1 c ts   = text c <+> intersperse comma (ppBase <$> ts)

ppBase (n,[]) = pp n
ppBase (n,ts) = pp n <> ppArgs angles comma ts

instance PP IndexKind where
  pp StringIndex  = text "string"
  pp NumericIndex = text "number"

instance (PP r, F.Reftable r) => PP (TypeMemberQ q r) where
  pp (CallSig t)          =  text "call" <+> pp t
  pp (ConsSig t)          =  text "new" <+> pp t
  pp (IndexSig _ i t)     =  brackets (pp i) <> text ":" <+> pp t
  pp (FieldSig x o m t)   =  text "▣" <+> ppMut m <+> pp x <> ppOptional o <> text ":" <+> pp t
  pp (MethSig x t)        =  text "●"             <+> pp x <+> text ":" <+>  ppMeth t

ppOptional t | optionalFieldType t = text "?"
             | isTVar t            = text "_"
             | otherwise           = text ""

ppMeth mt =
  case bkAnd mt of
    [ ] ->  text "ERROR TYPE"
    [t] ->  case bkFun t of
              Just ([],s,ts,t) -> ppfun s ts t
              Just (αs,s,ts,t) -> angles (ppArgs id comma αs) <> ppfun s ts t
              _                -> text "ERROR TYPE"
    ts  ->  vcat [text "/\\" <+> ppMeth t | t <- ts]
  where
    ppfun (Just s) ts t = ppArgs parens comma (B (F.symbol "this") s : ts) <> text ":" <+> pp t
    ppfun Nothing  ts t = ppArgs parens comma ts <> text ":" <+> pp t

mutSym (TRef (QN _ _ _ s) [] _)
  | s == F.symbol "Mutable"       = Just "_MU_"
  | s == F.symbol "UniqueMutable" = Just "_UM_"
  | s == F.symbol "Immutable"     = Just "_IM_"
  | s == F.symbol "AnyMutability" = Just "_AM_"
  | s == F.symbol "ReadOnly"      = Just "_RO_"
  | s == F.symbol "AssignsFields" = Just "_AF"
  | s == F.symbol "InheritedMut"  = Just "_IN_"
mutSym _                          = Nothing

ppMut t@TVar{} = pp t
ppMut t        | Just s <- mutSym t
               = pp s
               | otherwise
               = pp "_??_"

instance PP EnumDef where
  pp (EnumDef n m) = pp n <+> braces (pp m)

instance (PP r, F.Reftable r) => PP (ModuleDef r) where
  pp (ModuleDef vars tys enums path) =
          text "==================="
      $+$ text "module" <+> pp path
      $+$ text "==================="
      $+$ text "Variables"
      $+$ text "----------"
      $+$ braces (pp vars)
      $+$ text "-----"
      $+$ text "Types"
      $+$ text "-----"
      $+$ pp tys
      $+$ text "-----"
      $+$ text "Enums"
      $+$ text "-----"
      $+$ pp enums


-----------------------------------------------------------------------
-- | Primitive / Base Types
-----------------------------------------------------------------------

tVar                       :: (F.Reftable r) => TVar -> RType r
tVar                        = (`TVar` fTop)

isTVar (TVar _ _)           = True
isTVar _                    = False

tInt, tBool, tUndef, tNull, tString, tVoid, tErr :: (F.Reftable r) => RTypeQ q r
tInt                        = TApp TInt     [] fTop
tBV32                       = TApp TBV32    [] fTop
tBool                       = TApp TBool    [] fTop
tString                     = TApp TString  [] fTop
tTop                        = TApp TTop     [] fTop
tVoid                       = TApp TVoid    [] fTop
tUndef                      = TApp TUndef   [] fTop
tNull                       = TApp TNull    [] fTop
tErr                        = tVoid
tFunErr                     = ([],[],tErr)

isTFun (TFun _ _ _ _)       = True
isTFun (TAnd ts)            = all isTFun ts
isTFun (TAll _ t)           = isTFun t
isTFun _                    = False

isArr (TRef x _ _ )         = F.symbol x == F.symbol "Array"
isArr _                     = False

isTUndef (TApp TUndef _ _)  = True
isTUndef _                  = False

isTNull (TApp TNull _ _)    = True
isTNull _                   = False


isTVoid (TApp TVoid _ _ )   = True
isTVoid _                   = False

orNull t@(TApp TUn ts _)    | any isNull ts = t
orNull   (TApp TUn ts r)    | otherwise     = TApp TUn (tNull:ts) r
orNull t                    | isNull t      = t
orNull t                    | otherwise     = TApp TUn [tNull,t] fTop


---------------------------------------------------------------------------------
-- | Array literal types
---------------------------------------------------------------------------------

---------------------------------------------------------------------------------
arrayLitTy :: (F.Subable (RType r), IsLocated a) => a -> Int -> RType r -> RType r
---------------------------------------------------------------------------------
arrayLitTy l n ty
  = case ty of
      TAll μ (TAll α (TFun Nothing [xt] t r))
                  -> mkAll [μ,α] $ TFun Nothing (arrayLitBinds n xt) (substBINumArgs n t) r
      _           -> err
    where
      -- ty          = fst $ builtinOpTy l BIArrayLit g
      err         = die $ bug (srcPos l) $ "Bad Type for ArrayLit Constructor"

arrayLitBinds n (B x t) = [B (x_ i) t | i <- [1..n]]
  where
    xs            = symbolString x
    x_            = F.symbol . (xs ++) . show

substBINumArgs n t = F.subst1 t (F.symbol $ builtinOpId BINumArgs, F.expr (n::Int))


---------------------------------------------------------------------------------
-- | Object literal types
---------------------------------------------------------------------------------

-- FIXME: Avoid capture
freshTV l s n     = (v,t)
  where
    i             = F.intSymbol s n
    v             = TV i (srcPos l)
    t             = TVar v ()

--------------------------------------------------------------------------------------------
objLitTy         :: (F.Reftable r, IsLocated a) => a -> [Prop a] -> RType r
--------------------------------------------------------------------------------------------
objLitTy l ps     = mkFun (vs, Nothing, bs, rt)
  where
    vs            = [mv] ++ mvs ++ avs
    bs            = [B s (ofType a) | (s,a) <- zip ss ats ]
    rt            = TCons mt elts fTop
    elts          = M.fromList [ ((s, InstanceMember), FieldSig s f_required m $ ofType a)
                               | (s,m,a) <- zip3 ss mts ats ]
    (mv, mt)      = freshTV l mSym (0::Int)                      -- obj mutability
    (mvs, mts)    = unzip $ map (freshTV l mSym) [1..length ps]  -- field mutability
    (avs, ats)    = unzip $ map (freshTV l aSym) [1..length ps]  -- field type vars
    ss            = [F.symbol p | p <- ps]
    mSym          = F.symbol "M"
    aSym          = F.symbol "A"

lenId l           = Id l "length"
argId l           = Id l "arguments"

instance F.Symbolic (LValue a) where
  symbol (LVar _ x) = F.symbol x
  symbol lv         = convertError "F.Symbol" lv


instance F.Symbolic (Prop a) where
  symbol (PropId _ (Id _ x)) = F.symbol x -- TODO $ "propId_"     ++ x
  symbol (PropString _ s)    = F.symbol $ "propString_" ++ s
  symbol (PropNum _ n)       = F.symbol $ "propNum_"    ++ show n
  -- symbol p                   = error $ printf "Symbol of property %s not supported yet" (ppshow p)


-- | @argBind@ returns a dummy type binding `arguments :: T `
--   where T is an object literal containing the non-undefined `ts`.

mkArgTy l ts g = immObjectLitTy l g [pLen] [tLen]
                 -- immObjectLitTy l g (pLen : ps') (tLen : ts')
  where
    ts'        = take k ts
    ps'        = PropNum l . toInteger <$> [0 .. k-1]
    pLen       = PropId l $ lenId l
    tLen       = tInt `strengthen` rLen
    rLen       = F.ofReft $ F.uexprReft k
    k          = fromMaybe (length ts) $ L.findIndex isUndef ts


immObjectLitTy l _ ps ts
  | nps == length ts = TCons t_immutable elts fTop -- objLitR l nps g
  | otherwise        = die $ bug (srcPos l) $ "Mismatched args for immObjectLit"
  where
    elts             = M.fromList
                         [ ((s, InstanceMember), FieldSig s f_required t_immutable t)
                         | (p,t) <- safeZip "immObjectLitTy" ps ts, let s = F.symbol p ]
    nps              = length ps


---------------------------------------------------------------------------------
setPropTy :: (PPR r, IsLocated l) => l -> F.Symbol -> RType r -> RType r
---------------------------------------------------------------------------------
setPropTy l f ty =
    case ty of
      TAnd [TAll α1 (TAll μ1 (TFun Nothing [xt1,a1] rt1 r1)),
            TAll α2 (TAll μ2 (TFun Nothing [xt2,a2] rt2 r2))]

          -> TAnd [TAll α1 (TAll μ1 (TAll vOpt (TFun Nothing [gg xt1,a1] rt1 r1))),
                   TAll α2 (TAll μ2 (TAll vOpt (TFun Nothing [gg xt2,a2] rt2 r2)))]

      _   -> errorstar $ "setPropTy " ++ ppshow ty
  where
    gg (B n (TCons m ts r))        = B n (TCons m (ff ts) r)
    gg _                           = throw $ bug (srcPos l) "Unhandled cases in Typecheck.Types.setPropTy"
    ff                             = M.fromList . tr . M.toList
    tr [((_,a),FieldSig x _ μx t)] | x == F.symbol "f" = [((f,a),FieldSig f (tVar vOpt) μx t)]
    tr t                           = error $ "setPropTy:tr " ++ ppshow t
    vOpt                           = TV (F.symbol "O") (srcPos dummySpan)


---------------------------------------------------------------------------------
returnTy :: (PP r, F.Reftable r) => RType r -> Bool -> RType r
---------------------------------------------------------------------------------
returnTy t True  = mkFun ([], Nothing, [B (F.symbol "r") t], tVoid)
returnTy _ False = mkFun ([], Nothing, [], tVoid)

---------------------------------------------------------------------------------
finalizeTy :: (PP r, F.Reftable r, ExprReftable F.Symbol r) => RType r -> RType r
---------------------------------------------------------------------------------
finalizeTy t@(TRef x (m:ts) _)
  | isUniqueMutable m
  = mkFun ([mOut], Nothing, [B sx t], TRef x (tOut:ts) (uexprReft sx))
  where
    sx   = F.symbol "x_"
    tOut = tVar mOut
    mOut = TV (F.symbol "N") (srcPos dummySpan)
finalizeTy _
  = mkFun ([mV]  , Nothing, [B (F.symbol "x") tV], tV)
  where
    tV   = tVar mV
    mV   = TV (F.symbol "V") (srcPos dummySpan)



localTy t = mkFun ([], Nothing, [B sx t], t `strengthen` uexprReft sx)
  where
    sx    = F.symbol "x_"


-- | `mkEltFunTy`: Creates a function type that corresponds to an invocation
--   to the input element.
---------------------------------------------------------------------------------
mkEltFunTy :: F.Reftable r => TypeMember r -> Maybe (RType r)
---------------------------------------------------------------------------------
mkEltFunTy (MethSig _      t) = mkEltFromType t
mkEltFunTy (FieldSig _ _ _ t) = mkEltFromType t
mkEltFunTy _                  = Nothing

mkEltFromType = fmap (mkAnd . fmap (mkFun . squash)) . sequence . map bkFun . bkAnd
  where
    squash (αs, Just s, ts, t) = (αs, Nothing, B (F.symbol "this") s:ts, t)
    squash (αs, _     , ts, t) = (αs, Nothing, ts, t)


mkInitFldTy t = mkFun ([], Nothing, [B (F.symbol "f") t], tVoid)


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
prefixOpId o                = errorstar $ "prefixOpId: Cannot handle: " ++ ppshow o


mkId            = Id (initialPos "")
builtinId       = mkId . ("builtin_" ++)




-- | BitVectors

bitVectorValue ('0':x) = Just $ exprReft $ BV.Bv BV.S32  $ "#" ++ x
bitVectorValue _       = Nothing
