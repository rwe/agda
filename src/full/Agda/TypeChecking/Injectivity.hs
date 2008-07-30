{-# OPTIONS -cpp #-}

module Agda.TypeChecking.Injectivity where

import Prelude hiding (mapM)
import Control.Applicative
import Control.Monad hiding (mapM)
import Control.Monad.Error hiding (mapM)
import Control.Monad.State hiding (mapM)
import Control.Monad.Reader hiding (mapM)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Maybe
import Data.List
import Data.Traversable

import Agda.Syntax.Common
import Agda.Syntax.Internal
import Agda.TypeChecking.Monad
import Agda.TypeChecking.Substitute
import Agda.TypeChecking.Reduce
import Agda.TypeChecking.Primitive
import Agda.TypeChecking.MetaVars
import {-# SOURCE #-} Agda.TypeChecking.Conversion
import Agda.TypeChecking.Pretty
import Agda.TypeChecking.Constraints
import Agda.Utils.List
import Agda.Utils.Monad
import Agda.Utils.Permutation

#include "../undefined.h"
import Agda.Utils.Impossible

headSymbol :: Term -> TCM (Maybe TermHead)
headSymbol v = ignoreAbstractMode $ do
  v <- constructorForm v
  case v of
    Def f _ -> do
      def <- theDef <$> getConstInfo f
      case def of
        Datatype{}  -> return (Just $ ConHead f)
        Record{}    -> return (Just $ ConHead f)
        Axiom{}     -> return (Just $ ConHead f)
        _           -> return Nothing
    Con c _ -> return (Just $ ConHead c)
    Sort _  -> return (Just SortHead)
    Pi _ _  -> return (Just PiHead)
    Fun _ _ -> return (Just PiHead)
    Lit _   -> return Nothing -- handle literal heads as well? can't think of
                              -- any examples where it would be useful...
    _       -> return Nothing

checkInjectivity :: QName -> [Clause] -> TCM FunctionInverse
checkInjectivity f cs = do
  reportSLn "tc.inj.check" 40 $ "Checking injectivity of " ++ show f
  es <- concat <$> mapM entry cs
  let (hs, ps) = unzip es
  reportSLn "tc.inj.check" 40 $ "  right hand sides: " ++ show hs
  if all isJust hs && distinct hs
    then do
      let inv = Map.fromList (map fromJust hs `zip` ps)
      reportSLn "tc.inj.check" 20 $ show f ++ " is injective."
      reportSDoc "tc.inj.check" 30 $ nest 2 $ vcat $
        map (\ (h, Clause _ _ ps _) -> text (show h) <+> text "-->" <+>
                          fsep (punctuate comma $ map (text . show) ps)
            ) $ Map.toList inv
      return $ Inverse inv
    else return NotInjective
  where
    entry c@(Clause _ _ _ b) = do
      mv <- rhs b
      case mv of
        Nothing -> return []
        Just v  -> do
          h <- headSymbol v
          return [(h, c)]

    rhs (NoBind b) = rhs b
    rhs (Bind b)   = underAbstraction_ b rhs
    rhs (Body v)   = return $ Just v
    rhs NoBody     = return Nothing

-- | Argument should be on weak head normal form.
functionInverse :: Term -> TCM InvView
functionInverse v = case ignoreBlocking v of
  Def f args -> do
    d <- theDef <$> getConstInfo f
    case d of
      Function{ funInv = inv } -> case inv of
        NotInjective  -> return NoInv
        Inverse m     -> return $ Inv f args m
      _ -> return NoInv
  _ -> return NoInv

data InvView = Inv QName Args (Map TermHead Clause)
             | NoInv

useInjectivity :: Type -> Term -> Term -> TCM Constraints
useInjectivity a u v = do
  uinv <- functionInverse u
  vinv <- functionInverse v
  case (uinv, vinv) of
    (Inv f fArgs _, Inv g gArgs _)
      | f == g    -> do
        a <- defType <$> getConstInfo f
        reportSDoc "tc.inj.use" 20 $ vcat
          [ fsep (pwords "comparing application of injective function" ++ [prettyTCM f] ++
                pwords "at")
          , nest 2 $ fsep $ punctuate comma $ map prettyTCM fArgs
          , nest 2 $ fsep $ punctuate comma $ map prettyTCM gArgs
          , nest 2 $ text "and type" <+> prettyTCM a
          ]
        equalArgs a fArgs gArgs
      | otherwise -> fallBack
    (Inv f args inv, NoInv) -> do
      a <- defType <$> getConstInfo f
      reportSDoc "tc.inj.use" 20 $ fsep $
        pwords "inverting injective function" ++
        [ prettyTCM f, text ":", prettyTCM a, text "for", prettyTCM v
        , parens $ text "args =" <+> prettyList (map prettyTCM args)
        ]
      invert a inv args =<< headSymbol v
    (NoInv, Inv g args inv) -> do
      a <- defType <$> getConstInfo g
      reportSDoc "tc.inj.use" 20 $ fsep $
        pwords "inverting injective function" ++
        [ prettyTCM g, text ":", prettyTCM a,  text "for", prettyTCM u
        , parens $ text "args =" <+> prettyList (map prettyTCM args)
        ]
      invert a inv args =<< headSymbol u
    (NoInv, NoInv)          -> fallBack
  where
    fallBack = buildConstraint $ ValueEq a u v

    invert a inv args Nothing  = fallBack
    invert ftype inv args (Just h) = case Map.lookup h inv of
      Nothing                     -> typeError $ UnequalTerms u v a
      Just (Clause tel perm ps _) -> do -- instArgs args ps
          -- These are what dot patterns should be instantiated at
          ms <- map unArg <$> newTelMeta tel
          reportSDoc "tc.inj.invert" 20 $ vcat
            [ text "meta patterns" <+> prettyList (map prettyTCM ms)
            , text "  perm =" <+> text (show perm)
            , text "  tel  =" <+> prettyTCM tel
            , text "  ps   =" <+> prettyList (map (text . show) ps)
            ]
          -- and this is the order the variables occur in the patterns
          let ms' = permute (invertP $ compactP perm) ms
          cxt <- getContextTelescope
          let sub = (reverse ms ++ idSub cxt)
          margs <- runReaderT (evalStateT (metaArgs ps) ms') sub
          reportSDoc "tc.inj.invert" 20 $ vcat
            [ text "inversion"
            , nest 2 $ vcat
              [ text "lhs  =" <+> prettyList (map prettyTCM margs)
              , text "rhs  =" <+> prettyList (map prettyTCM args)
              , text "type =" <+> prettyTCM ftype
              ]
            ]
          cs <- equalArgs ftype margs args
          unless (null cs) patternViolation
          equalTerm a u v
        `catchError` \err -> case err of
          TypeError _ _ -> throwError err
          Exception _ _ -> throwError err
          PatternErr _  -> fallBack
          AbortAssign _ -> fallBack

    nextMeta = do
      m : ms <- get
      put ms
      return m

    dotP v = do
      sub <- ask
      return $ substs sub v

    metaArgs args = mapM metaArg args
    metaArg arg = traverse metaPat arg

    metaPat (DotP v) = dotP v
    metaPat (VarP _) = nextMeta
    metaPat (ConP c args) = Con c <$> metaArgs args
    metaPat (LitP l) = return $ Lit l

