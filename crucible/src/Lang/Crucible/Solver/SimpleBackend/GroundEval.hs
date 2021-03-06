------------------------------------------------------------------------
-- |
-- Module      : Lang.Crucible.Solver.SimpleBackend.GroundEval
-- Description : Computing ground values for expressions from solver assignments
-- Copyright   : (c) Galois, Inc 2016
-- License     : BSD3
-- Maintainer  : Joe Hendrix <jhendrix@galois.com>
-- Stability   : provisional
--
-- Given a collection of assignments to the symbolic values appearing in
-- an expression, this module computes the ground value.
------------------------------------------------------------------------

{-# LANGUAGE DataKinds #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}
module Lang.Crucible.Solver.SimpleBackend.GroundEval
  ( GroundValue
  , GroundValueWrapper(..)
  , GroundEvalFn(..)
  , EltRangeBindings
  , tryEvalGroundElt
  , evalGroundElt
  , evalGroundApp
  , evalGroundNonceApp
  , defaultValueForType
  ) where

import           Control.Monad
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Maybe
import           Data.Bits
import qualified Data.Map.Strict as Map
import qualified Data.Parameterized.Context as Ctx
import           Data.Parameterized.NatRepr
import           Data.Parameterized.TraversableFC
import           Data.Ratio

import           Lang.MATLAB.Utils.Nat

import           Lang.Crucible.BaseTypes
import           Lang.Crucible.Solver.Interface
import           Lang.Crucible.Solver.SimpleBuilder
import qualified Lang.Crucible.Solver.WeightedSum as WSum
import           Lang.Crucible.Utils.Arithmetic ( roundAway )
import           Lang.Crucible.Utils.Complex
import qualified Lang.Crucible.Utils.Hashable as Hash
import qualified Lang.Crucible.Utils.UnaryBV as UnaryBV

type family GroundValue (tp :: BaseType) where
  GroundValue BaseBoolType     = Bool
  GroundValue BaseNatType      = Nat
  GroundValue BaseIntegerType  = Integer
  GroundValue BaseRealType     = Rational
  GroundValue (BaseBVType w)   = Integer
  GroundValue BaseComplexType  = Complex Rational
  GroundValue (BaseArrayType idx b)  =
    Ctx.Assignment GroundValueWrapper idx -> IO (GroundValue b)
  GroundValue (BaseStructType ctx) = Ctx.Assignment GroundValueWrapper ctx

-- | A function that calculates ground values for elements.
newtype GroundEvalFn t = GroundEvalFn { groundEval :: forall tp . Elt t tp -> IO (GroundValue tp) }

-- | Function that calculates upper and lower bounds for real-valued elements.
--   This type is used for solvers (e.g., dReal) that give only approximate solutions.
type EltRangeBindings t = RealElt t -> IO (Maybe Rational, Maybe Rational)

-- | A newtype wrapper around ground value for use in a cache.
newtype GroundValueWrapper tp = GVW { unGVW :: GroundValue tp }

asIndexLit :: BaseTypeRepr tp -> GroundValueWrapper tp -> Maybe (IndexLit tp)
asIndexLit BaseNatRepr    (GVW v) = return $ NatIndexLit v
asIndexLit (BaseBVRepr w) (GVW v) = return $ BVIndexLit w v
asIndexLit _ _ = Nothing

-- | Convert a real standardmodel val to a double.
toDouble :: Rational -> Double
toDouble = fromRational

fromDouble :: Double -> Rational
fromDouble = toRational

defaultValueForType :: BaseTypeRepr tp -> GroundValue tp
defaultValueForType tp =
  case tp of
    BaseBoolRepr    -> False
    BaseNatRepr     -> 0
    BaseBVRepr _    -> 0
    BaseIntegerRepr -> 0
    BaseRealRepr    -> 0
    BaseComplexRepr -> 0 :+ 0
    BaseArrayRepr _ b -> \_ -> return (defaultValueForType b)
    BaseStructRepr ctx -> fmapFC (GVW . defaultValueForType) ctx

{-# INLINABLE evalGroundElt #-}
evalGroundElt :: (forall u . Elt t u -> IO (GroundValue u))
              -> Elt t tp
              -> IO (GroundValue tp)
evalGroundElt f e =
 runMaybeT (tryEvalGroundElt f e) >>= \case
    Nothing -> fail $ unwords ["evalGroundElt: could not evaluate expression:", show e]
    Just x  -> return x

{-# INLINABLE tryEvalGroundElt #-}
-- | Evaluate an element, when given an evaluation function for
--   subelements.  Instead of recursing directly, `tryEvalGroundElt`
--   calls into the given function on sub-elements to allow the caller
--   to cache results if desired.
--
--   However, sometimes we are unable to compute expressions outside
--   the solver.  In these cases, this function will return `Nothing`
--   in the `MaybeT IO` monad.  In these cases, the caller should instead
--   query the solver directly to evaluate the expression, if possible.
tryEvalGroundElt :: (forall u . Elt t u -> IO (GroundValue u))
                 -> Elt t tp
                 -> MaybeT IO (GroundValue tp)
tryEvalGroundElt _ (NatElt c _) = return c
tryEvalGroundElt _ (IntElt c _) = return c
tryEvalGroundElt _ (RatElt c _) = return c
tryEvalGroundElt _ (BVElt _ c _) = return c
tryEvalGroundElt f (NonceAppElt a0) = evalGroundNonceApp (lift . f) (nonceEltApp a0)
tryEvalGroundElt f (AppElt a0)      = evalGroundApp f (appEltApp a0)
tryEvalGroundElt _ (BoundVarElt v) =
  case bvarKind v of
    QuantifierVarKind -> fail $ "The ground evaluator does not support bound variables."
    LatchVarKind      -> return $! defaultValueForType (bvarType v)
    UninterpVarKind   -> return $! defaultValueForType (bvarType v)

{-# INLINABLE evalGroundNonceApp #-}
evalGroundNonceApp :: Monad m
                   => (forall u . Elt t u -> MaybeT m (GroundValue u))
                   -> NonceApp t (Elt t) tp
                   -> MaybeT m (GroundValue tp)
evalGroundNonceApp _ a0 = lift $ fail $
  case a0 of
    Forall{} -> "The ground evaluator does not support quantifiers."
    Exists{} -> "The ground evaluator does not support quantifiers."
    MapOverArrays{} -> "The ground evaluator does not support mapping arrays from arbitrary functions."
    ArrayFromFn{} -> "The ground evaluator does not support arrays from arbitrary functions."
    ArrayTrueOnEntries{} -> "The ground evaluator does not support arrayTrueOnEntries."
    FnApp{}  -> "The ground evaluator does not support function applications."

{-# INLINABLE evalGroundApp #-}

forallIndex :: Ctx.Size (ctx :: Ctx.Ctx k) -> (forall tp . Ctx.Index ctx tp -> Bool) -> Bool
forallIndex sz f = Ctx.forIndex sz (\b j -> f j && b) True

evalGroundApp :: forall t tp
               . (forall u . Elt t u -> IO (GroundValue u))
              -> App (Elt t) tp
              -> MaybeT IO (GroundValue tp)
evalGroundApp f0 a0 = do
  let f :: forall u . Elt t u -> MaybeT IO (GroundValue u)
      f = lift . f0
  case a0 of

    TrueBool -> return True
    FalseBool -> return False
    NotBool b -> not <$> f b
    AndBool x y -> do
      xv <- f x
      if xv then f y else return False
    XorBool x y -> (/=) <$> f x <*> f y
    IteBool x y z -> do
      xv <- f x
      if xv then f y else f z

    RealEq x y -> (==) <$> f x <*> f y
    RealLe x y -> (<=) <$> f x <*> f y
    RealIsInteger x -> (\xv -> denominator xv == 1) <$> f x
    BVTestBit i x -> (`testBit` i) <$> f x
    BVEq  x y -> (==) <$> f x <*> f y
    BVSlt x y -> (<) <$> (toSigned w <$> f x)
                     <*> (toSigned w <$> f y)
      where w = bvWidth x
    BVUlt x y -> (<) <$> f x <*> f y

    -- Note, we punt on calculating the value of array equalities beacause it is
    -- difficult to get accurate models of arrays out of solvers.
    ArrayEq _x _y -> mzero

    NatDiv x y -> g <$> f x <*> f y
      where g _ 0 = 0
            g u v = u `div` v
    IntMod  x y -> intModu <$> f x <*> f y
      where intModu _ 0 = 0
            intModu i v = fromInteger (i `mod` toInteger v)

    RealMul x y -> (*) <$> f x <*> f y
    RealSum s -> WSum.eval (\x y -> (+) <$> x <*> y) smul pure s
      where smul sm e = (sm *) <$> f e
    RealIte x y z -> do
      xv <- f x
      if xv then f y else f z
    RealDiv x y -> do
      xv <- f x
      yv <- f y
      return $!
        if yv == 0 then 0 else xv / yv
    RealSqrt x -> do
      xv <- f x
      when (xv < 0) $ do
        lift $ fail $ "Model returned sqrt of negative number."
      return $ fromDouble (sqrt (toDouble xv))

    ------------------------------------------------------------------------
    -- Operations that introduce irrational numbers.

    Pi -> return $ fromDouble pi
    RealSin x -> fromDouble . sin . toDouble <$> f x
    RealCos x -> fromDouble . cos . toDouble <$> f x
    RealATan2 x y -> do
      xv <- f x
      yv <- f y
      return $ fromDouble (atan2 (toDouble xv) (toDouble yv))
    RealSinh x -> fromDouble . sinh . toDouble <$> f x
    RealCosh x -> fromDouble . cosh . toDouble <$> f x

    RealExp x -> fromDouble . exp . toDouble <$> f x
    RealLog x -> fromDouble . log . toDouble <$> f x

    ------------------------------------------------------------------------
    -- Bitvector Operations

    BVUnaryTerm u -> do
      UnaryBV.evaluate f u
    BVConcat w x y -> cat <$> f x <*> f y
      where w2 = bvWidth y
            cat a b = toUnsigned w $ a `shiftL` (fromIntegral (natValue w2)) .|. b
    BVSelect idx n x -> sel <$> f x
      where sel a = toUnsigned n (a `shiftR` shft)
            shft = fromIntegral (natValue (bvWidth x) - natValue idx - natValue n)
    BVNeg w x -> toUnsigned w <$> f x
    BVAdd w x y -> toUnsigned w <$> ((+) <$> f x <*> f y)
    BVMul w x y -> toUnsigned w <$> ((*) <$> f x <*> f y)
    BVUdiv w x y -> toUnsigned w <$> (myDiv <$> f x <*> f y)
      where myDiv _ 0 = 0
            myDiv u v = u `div` v
    BVUrem w x y -> toUnsigned w <$> (myRem <$> f x <*> f y)
      where myRem u 0 = u
            myRem u v = u `rem` v
    BVSdiv w x y -> toUnsigned w <$> (myDiv <$> f x <*> f y)
      where myDiv _ 0 = 0
            myDiv u v = toSigned w u `div` toSigned w v
    BVSrem w x y -> toUnsigned w <$> (myRem <$> f x <*> f y)
      where myRem u 0 = u
            myRem u v = toSigned w u `rem` toSigned w v
    BVIte _ _ x y z -> do
      xv <- f x
      if xv then f y else f z
    BVShl  w x y -> toUnsigned w <$> (shiftL <$> f x <*> (fromInteger <$> f y))
    BVLshr w x y -> lift $
      toUnsigned w <$> (shiftR <$> f0 x <*> (fromInteger <$> f0 y))
    BVAshr w x y -> lift $
      toUnsigned w <$> (shiftR <$> (toSigned w <$> f0 x) <*> (fromInteger <$> f0 y))
    BVZext _ x -> lift $ f0 x
    BVSext w x -> lift $ do
      case isPosNat w of
        Just LeqProof -> (toUnsigned w . toSigned w) <$> f0 x
        Nothing -> error "BVSext given bad width"
    BVTrunc w x -> lift $ toUnsigned w <$> f0 x

    BVBitNot _ x   -> lift $ complement <$> f0 x
    BVBitAnd _ x y -> lift $ (.&.) <$> f0 x <*> f0 y
    BVBitOr  _ x y -> lift $ (.|.) <$> f0 x <*> f0 y
    BVBitXor _ x y -> lift $ xor <$> f0 x <*> f0 y

    ------------------------------------------------------------------------
    -- Array Operations

    ArrayMap idx_types _ m def -> lift $ do
      m' <- traverse f0 (Hash.hashedMap m)
      h <- f0 def
      let g idx =
            case (`Map.lookup` m') =<< Ctx.zipWithM asIndexLit idx_types idx of
              Just r ->  return r
              Nothing -> h idx
      return $ g
    ConstantArray _ _ v -> lift $ do
      val <- f0 v
      return $ \_ -> return val

    MuxArray _ _ p x y -> lift $ do
      b <- f0 p
      if b then f0 x else f0 y

    SelectArray _ a i -> do
      arr <- f a
      idx <- traverseFC (\e -> GVW <$> f e) i
      lift $ arr idx

    UpdateArray _ idx_tps a i v -> do
      arr <- f a
      idx <- traverseFC (\e -> GVW <$> f e) i
      return $ (\x -> if indicesEq idx_tps idx x then f0 v else arr x)

     where indicesEq :: Ctx.Assignment BaseTypeRepr ctx
                     -> Ctx.Assignment GroundValueWrapper ctx
                     -> Ctx.Assignment GroundValueWrapper ctx
                     -> Bool
           indicesEq tps x y =
             forallIndex (Ctx.size x) $ \j -> do
               let GVW xj = x Ctx.! j
               let GVW yj = y Ctx.! j
               let tp = tps Ctx.! j
               case tp of
                 BaseNatRepr  -> xj == yj
                 BaseBVRepr _ -> xj == yj
                 _ -> error $ "We do not yet support UpdateArray on " ++ show tp ++ " indices."

    ------------------------------------------------------------------------
    -- Conversions

    NatToInteger x -> toInteger <$> f x
    IntegerToReal x -> toRational <$> f x
    BVToInteger x  -> f x
    SBVToInteger x -> toSigned (bvWidth x) <$> f x

    RoundReal x -> roundAway <$> f x
    FloorReal x -> floor <$> f x
    CeilReal  x -> ceiling <$> f x

    RealToInteger x -> floor <$> f x

    IntegerToNat x -> fromInteger . max 0 <$> f x
    IntegerToSBV x w -> toUnsigned w . signedClamp w <$> f x
    IntegerToBV x w -> unsignedClamp w <$> f x

    ------------------------------------------------------------------------
    -- Complex operations.

    Cplx (x :+ y) -> (:+) <$> f x <*> f y
    RealPart x -> realPart <$> f x
    ImagPart x -> imagPart <$> f x

    ------------------------------------------------------------------------
    -- Structs

    StructCtor _ flds -> do
      traverseFC (\v -> GVW <$> f v) flds
    StructField s i _ -> do
      sv <- f s
      return $! unGVW (sv Ctx.! i)
    StructIte _ p x y -> do
      pv <- f p
      if pv then f x else f y
