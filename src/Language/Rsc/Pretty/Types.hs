{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE DeriveFoldable            #-}
{-# LANGUAGE DeriveFunctor             #-}
{-# LANGUAGE DeriveGeneric             #-}
{-# LANGUAGE DeriveTraversable         #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE IncoherentInstances       #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE OverlappingInstances      #-}
{-# LANGUAGE TupleSections             #-}
{-# LANGUAGE TypeSynonymInstances      #-}
{-# LANGUAGE UndecidableInstances      #-}

module Language.Rsc.Pretty.Types (

) where

import           Control.Applicative               ((<$>))
import           Data.Graph.Inductive.Graph
import           Data.Graph.Inductive.PatriciaTree
import qualified Data.Map.Strict                   as M
import           Language.Fixpoint.Misc            (intersperse)
import qualified Language.Fixpoint.Types           as F
import           Language.Rsc.AST
import           Language.Rsc.Pretty.Common
import           Language.Rsc.Pretty.Syntax
import           Language.Rsc.Program
import           Language.Rsc.Typecheck.Types
import           Language.Rsc.Types
import           Text.PrettyPrint.HughesPJ

angles p = char '<' <> p <> char '>'
ppHMap p = map (p . snd) . M.toList

instance PP Bool where
  pp True   = text "True"
  pp False  = text "False"

instance PP () where
  pp _ = text ""

instance PP a => PP (Maybe a) where
  pp = maybe (text "Nothing") pp

instance PP Char where
  pp = char

instance (F.Reftable r, PP r) => PP (RTypeQ q r) where
  pp (TPrim c r)     = F.ppTy r $ pp c
  pp (TVar α r)      = F.ppTy r $ (text "#" <> pp α)
  pp (TOr ts)        = ppArgs id (text " +") ts
  pp (TAnd ts)       = vcat [text "/\\" <+> pp t | t <- ts]
  pp (TRef t r)      = F.ppTy r $ pp t
  pp (TObj ms r)     = F.ppTy r $ braces $ pp ms
  pp (TClass t)      = text "class" <+> pp t
  pp (TMod t)        = text "module" <+> pp t
  pp t@(TAll _ _)    = ppArgs angles comma αs <> text "." <+> pp t' where (αs, t') = bkAll t
  pp (TFun xts t _)  = ppArgs parens comma xts <+> text "=>" <+> pp t
  pp (TExp e)        = pprint e

instance (F.Reftable r, PP r) => PP (TypeMembersQ q r) where
  pp (TM fs ms sfs sms cs cts sidx nidx)
    = ppProp fs  <+> ppMeth ms  <+> ppSProp sfs <+> ppSMeth sms <+>
      ppCall cs  <+> ppCtor cts <+> ppSIdx sidx <+> ppNIdx nidx

ppProp  = vcat . map (\(x, f) -> pp x <> pp f) . F.toListSEnv
ppMeth  = vcat . map (\(x, m) -> pp x <> pp m) . F.toListSEnv
ppSProp = vcat . map (\(x, f) -> pp "static" <+> pp x <> pp f) . F.toListSEnv
ppSMeth = vcat . map (\(x, m) -> pp "static" <+> pp x <> pp m) . F.toListSEnv
ppCall optT | Just t <- optT = pp t              | otherwise = pp ""
ppCtor optT | Just t <- optT = pp "new" <+> pp t | otherwise = pp ""
ppSIdx t = pp "[x: string]:" <+> pp t
ppNIdx t = pp "[x: number]:" <+> pp t

instance PPR r => PP (FieldInfoQ q r) where
  pp (FI o m t) = brackets (pp m) <> pp o <> colon <+> pp t

instance PPR r => PP (MethodInfoQ q r) where
  pp (MI o m t) = pp o <> brackets (pp m) <> pp t

instance PP Optionality where
  pp Opt = text "?"
  pp Req = text ""

instance (F.Reftable r, PP r) => PP (TGenQ q r) where
  pp (Gen x ts) = pp x <> ppArgs angles comma ts

instance (F.Reftable r, PP r) => PP (BTGenQ q r) where
  pp (BGen x ts) = pp x <> ppArgs angles comma ts

instance PP TVar where
  pp = pprint . F.symbol

instance (F.Reftable r, PP r) => PP (BTVarQ q r) where
  pp (BTV v t _) = pprint v <+> text "<:" <+> pp t

instance PP TPrim where
  pp TString     = text "string"
  pp (TStrLit s) = text "\"" <> text s <> text "\""
  pp TNumber     = text "number"
  pp TBoolean    = text "boolean"
  pp TBV32       = text "bitvector32"
  pp TVoid       = text "void"
  pp TUndefined  = text "undefined"
  pp TNull       = text "null"
  pp TBot        = text "_|_"
  pp TTop        = text " T "

instance (PP r, F.Reftable r) => PP (BindQ q r) where
  pp (B x t) = pp x <> colon <> pp t

instance (PP s, PP t) => PP (M.Map s t) where
  pp m = vcat $ pp <$> M.toList m

instance PP Assignability where
  pp Ambient      = text "Ambient"
  pp WriteLocal   = text "WriteLocal"
  pp ForeignLocal = text "ForeignLocal"
  pp WriteGlobal  = text "WriteGlobal"
  pp ReturnVar    = text "ReturnVar"

instance PP MutabilityMod where
  pp Mutable       = text "MU"
  pp Immutable     = text "IM"
  pp AssignsFields = text "AF"
  pp ReadOnly      = text "RO"

instance (PP r, F.Reftable r) => PP (TypeDeclQ q r) where
  pp (TD s m) = pp s <+> lbrace $+$ nest 2 (pp m) $+$ rbrace

instance (PP r, F.Reftable r) => PP (TypeSigQ q r) where
  pp (TS k n h) = pp k <+> pp n <+> ppHeritage h

instance PP TypeDeclKind where
  pp InterfaceTDK = text "interface"
  pp ClassTDK     = text "class"

ppHeritage (es,is) = ppExtends es <+> ppImplements is

ppExtends []    = text ""
ppExtends (n:_) = text "extends" <+> pp n

ppImplements [] = text ""
ppImplements ts = text "implements" <+> intersperse comma (pp <$> ts)

mutSym (TRef n _) | s == F.symbol "Mutable"       = Just "_MU_"
                  | s == F.symbol "UniqueMutable" = Just "_UM_"
                  | s == F.symbol "Immutable"     = Just "_IM_"
                  | s == F.symbol "ReadOnly"      = Just "_RO_"
                  | s == F.symbol "AssignsFields" = Just "_AF"
  where s = F.symbol n
mutSym _ = Nothing

ppMut t@TVar{} = pp t
ppMut t        | Just s <- mutSym t = pp s
               | otherwise          = pp "_??_"

instance PP EnumDef where
  pp (EnumDef n m) = pp n <+> braces (pp m)

instance (F.Reftable r, PP r) => PP (VarInfo r) where
  pp (VI _ _ t) = pp t

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

instance PP IContext where
  pp (IC x) = text "Context: " <+> pp x

instance PP Initialization where
  pp Initialized   = text "init"
  pp Uninitialized = text "non-init"

instance (PP a, PP s, PP t) => PP (Alias a s t) where
  pp (Alias n _ _ body) = text "alias" <+> pp n <+> text "=" <+> pp body

instance (PP r, F.Reftable r) => PP (Rsc a r) where
  pp pgm@(Rsc {code = (Src s) })
    =   text "\n******************* Code **********************"
    $+$ pp s
    $+$ text "\n******************* Constants *****************"
    $+$ pp (consts pgm)
    $+$ text "\n******************* Predicate Aliases *********"
    $+$ pp (pAlias pgm)
    $+$ text "\n******************* Type Aliases **************"
    $+$ pp (tAlias pgm)
    $+$ text "\n******************* Qualifiers ****************"
    $+$ vcat (F.toFix <$> take 3 (pQuals pgm))
    $+$ text "..."
    $+$ text "\n******************* Invariants ****************"
    $+$ vcat (pp <$> invts pgm)
    $+$ text "\n***********************************************\n"

-- | PP Fixpoint

instance PP (F.SortedReft) where
  pp (F.RR _ b) = pp b

instance PP F.Reft where
  pp = pprint

instance PP (F.SubC c) where
  pp s = pp (F.lhsCs s) <+> text " <: " <+> pp (F.rhsCs s)
