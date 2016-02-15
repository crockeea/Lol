{-# LANGUAGE ConstraintKinds, DataKinds, FlexibleContexts,
             FlexibleInstances, GADTs, MultiParamTypeClasses,
             NoImplicitPrelude, PolyKinds, RankNTypes, ScopedTypeVariables,
             TypeFamilies, TypeOperators, UndecidableInstances #-}

-- | An implementation of cyclotomic rings that hides the
-- internal representations of ring elements (e.g., the choice of
-- basis), and also offers more efficient storage and operations on
-- subring elements (including elements from the base ring itself).
--
-- For an implementation that allows (and requires) the programmer to
-- control the underlying representation, see
-- 'Crypto.Lol.Cyclotomic.UCyc.UCyc'.
--
-- __WARNING:__ as with all fixed-point arithmetic, the functions
-- associated with 'Cyc' may result in overflow (and thereby
-- incorrect answers and potential security flaws) if the input
-- arguments are too close to the bounds imposed by the base type.
-- The acceptable range of inputs for each function is determined by
-- the internal linear transforms and other operations it performs.

module Crypto.Lol.Cyclotomic.Cyc
(
-- * Data type and constraint
  Cyc, CElt
-- * Constructors/deconstructors
, cycPow, cycDec, cycCRT, scalarCyc, uncycPow, uncycDec, uncycCRT
-- * Core cyclotomic operations
, mulG, divG, gSqNorm, liftCyc, liftPow, liftDec
, advisePow, adviseDec, adviseCRT
-- * Error sampling
, tGaussian, errorRounded, errorCoset
-- * Sub/extension rings
, embed, twace, coeffsCyc, powBasis, crtSet
-- * Rescaling cyclotomic elements
, R.RescaleCyc(..), R.Basis
) where

import qualified Algebra.Additive     as Additive (C)
import qualified Algebra.Ring         as Ring (C)
import qualified Algebra.ZeroTestable as ZeroTestable (C)

import Crypto.Lol.Cyclotomic.UCyc hiding (coeffsDec, coeffsPow, crtSet,
                                   divG, errorCoset, errorRounded, gSqNorm,
                                   mulG, powBasis, tGaussian, unzipCyc)

import           Crypto.Lol.CRTrans
import qualified Crypto.Lol.Cyclotomic.RescaleCyc as R
import           Crypto.Lol.Cyclotomic.Tensor     (CRTElt, TElt, Tensor)
import qualified Crypto.Lol.Cyclotomic.UCyc       as U
import           Crypto.Lol.Gadget
import           Crypto.Lol.LatticePrelude        as LP
import           Crypto.Lol.Types.ZPP

import Control.Applicative    hiding ((*>))
import Control.Arrow
import Control.DeepSeq
import Control.Monad.Identity   -- needed for coerce
import Control.Monad.Random
import Data.Coerce
import Data.Traversable

import Test.QuickCheck

-- | TODO documentation.
data Cyc t m r where
  Pow :: !(UCyc t m P r) -> Cyc t m r
  Dec :: !(UCyc t m D r) -> Cyc t m r
  CRT :: !(UCyc t m C r) -> Cyc t m r
  -- super-optimized storage of scalars
  Scalar :: !r -> Cyc t m r
  -- optimized storage of subring elements
  Sub :: (l `Divides` m) => !(Cyc t l r) -> Cyc t m r
  -- CJP: someday try to merge the above two

-- | Constraints needed for many operations involving 'Cyc' data.
type CElt t r = UCElt t r

---------- Constructors / deconstructors ----------

-- | Wrap a 'UCyc' as a 'Cyc'.
cycPow :: UCyc t m P r -> Cyc t m r
cycPow = Pow
{-# INLINABLE cycPow #-}

-- | Wrap a 'UCyc' as a 'Cyc'.
cycDec :: UCyc t m D r -> Cyc t m r
cycDec = Dec
{-# INLINABLE cycDec #-}

-- | Wrap a 'UCyc' as a 'Cyc'.
cycCRT :: UCyc t m C r -> Cyc t m r
cycCRT = CRT
{-# INLINABLE cycCRT #-}

-- | Embed a scalar from the base ring as a cyclotomic element.
scalarCyc :: r -> Cyc t m r
scalarCyc = Scalar
{-# INLINABLE scalarCyc #-}

-- | Unwrap a 'Cyc' as a 'UCyc' in powerful-basis representation.
uncycPow :: (Fact m, CElt t r) => Cyc t m r -> UCyc t m P r
{-# INLINABLE uncycPow #-}
uncycPow (Pow u) = u
uncycPow (Dec u) = U.toPow u
uncycPow (CRT u) = U.toPow u
uncycPow (Scalar u) = scalarPow u
uncycPow (Sub c) = uncycPow $ embed c

-- | Unwrap a 'Cyc' as a 'UCyc' in decoding-basis representation.
uncycDec :: (Fact m, CElt t r) => Cyc t m r -> UCyc t m D r
{-# INLINABLE uncycDec #-}
uncycDec (Pow u) = U.toDec u
uncycDec (Dec u) = u
uncycDec (CRT u) = U.toDec u
uncycDec (Scalar u) = scalarDec u
uncycDec (Sub c) = uncycDec $ embed c

-- | Unwrap a 'Cyc' as a 'UCyc' in CRT-basis representation.
uncycCRT :: (Fact m, CElt t r) => Cyc t m r -> UCyc t m C r
{-# INLINABLE uncycCRT #-}
uncycCRT (Pow u) = U.toCRT u
uncycCRT (Dec u) = U.toCRT u
uncycCRT (CRT u) = u
uncycCRT (Scalar u) = scalarCRT u
uncycCRT (Sub c) = uncycCRT $ embed c

---------- Algebraic instances ----------

instance (Fact m, CElt t r) => ZeroTestable.C (Cyc t m r) where
  isZero (Pow u) = isZero u
  isZero (Dec u) = isZero u
  isZero (CRT u) = isZero u
  isZero (Scalar c) = isZero c
  isZero (Sub c) = isZero c
  {-# INLINABLE isZero #-}

instance (Eq r, Fact m, CElt t r) => Eq (Cyc t m r) where
  -- same representations
  (Scalar c1) == (Scalar c2) = c1 == c2
  (Pow u1) == (Pow u2) = u1 == u2
  (Dec u1) == (Dec u2) = u1 == u2
  (CRT u1) == (CRT u2) = u1 == u2
  -- compare Subs in compositum
  (Sub (c1 :: Cyc t l1 r)) == (Sub (c2 :: Cyc t l2 r)) =
    (embed' c1 :: Cyc t (FLCM l1 l2) r) == embed' c2
    \\ lcmDivides (Proxy::Proxy l1) (Proxy::Proxy l2)

  -- some other relatively efficient comparisons
  (Scalar c1) == (Pow u2) = scalarPow c1 == u2
  (Scalar c1) == (Dec u2) = scalarDec c1 == u2
  (Pow u1) == (Scalar c2) = u1 == scalarPow c2
  (Dec u1) == (Scalar c2) = u1 == scalarDec c2

  -- default: compare in powerful basis
  c1 == c2 = toPow' c1 == toPow' c2

  {-# INLINABLE (==) #-}

instance (Fact m, CElt t r) => Additive.C (Cyc t m r) where
  {-# INLINABLE zero #-}
  zero = Scalar zero

  {-# INLINABLE (+) #-}
  -- optimized addition of zero
  (Scalar c1) + c2 | isZero c1 = c2
  c1 + (Scalar c2) | isZero c2 = c1

  -- SAME CONSTRUCTORS
  (Scalar c1) + (Scalar c2) = Scalar (c1+c2)
  (Pow u1) + (Pow u2) = Pow $ u1 + u2
  (Dec u1) + (Dec u2) = Dec $ u1 + u2
  (CRT u1) + (CRT u2) = CRT $ u1 + u2
  -- Sub plus Sub: work in compositum
  (Sub (c1 :: Cyc t m1 r)) + (Sub (c2 :: Cyc t m2 r)) =
    (Sub $ (embed' c1 :: Cyc t (FLCM m1 m2) r) + embed' c2)
    \\ lcm2Divides (Proxy::Proxy m1) (Proxy::Proxy m2) (Proxy::Proxy m)

  -- SCALAR PLUS SOMETHING ELSE

  (Scalar c) + (Pow u) = Pow $ scalarPow c + u
  (Scalar c) + (Dec u) = Dec $ scalarDec c + u
  (Scalar c) + (CRT u) = CRT $ scalarCRT c + u
  (Scalar c1) + (Sub c2) = Sub $ Scalar c1 + c2 -- must re-wrap Scalar!

  (Pow u) + (Scalar c) = Pow $ u + scalarPow c
  (Dec u) + (Scalar c) = Dec $ u + scalarDec c
  (CRT u) + (Scalar c) = CRT $ u + scalarCRT c
  (Sub c1) + (Scalar c2) = Sub $ c1 + Scalar c2

  -- SUB PLUS NON-SUB, NON-SCALAR: work in full ring
  (Sub c1) + c2 = embed' c1 + c2
  c1 + (Sub c2) = c1 + embed' c2

  -- mixed Dec and Pow: use linear-time conversions
  (Dec u1) + (Pow u2) = Pow $ toPow u1 + u2
  (Pow u1) + (Dec u2) = Pow $ u1 + toPow u2

  -- one CRT: convert other to CRT
  (CRT u1) + (Pow u2) = CRT $ u1 + toCRT u2
  (CRT u1) + (Dec u2) = CRT $ u1 + toCRT u2
  (Pow u1) + (CRT u2) = CRT $ toCRT u1 + u2
  (Dec u1) + (CRT u2) = CRT $ toCRT u1 + u2

  {-# INLINABLE negate #-}
  negate (Pow u) = Pow $ negate u
  negate (Dec u) = Dec $ negate u
  negate (CRT u) = CRT $ negate u
  negate (Scalar c) = Scalar (negate c)
  negate (Sub c) = Sub $ negate c

instance (Fact m, CElt t r) => Ring.C (Cyc t m r) where
  {-# INLINABLE one #-}
  one = Scalar one

  {-# INLINABLE fromInteger #-}
  fromInteger = Scalar . fromInteger

  {-# INLINABLE (*) #-}

  -- optimized mul-by-zero
  v1@(Scalar c1) * _ | isZero c1 = v1
  _ * v2@(Scalar c2) | isZero c2 = v2

  -- both CRT
  (CRT u1) * (CRT u2) = CRT $ u1*u2

  -- at least one Scalar
  (Scalar c1) * (Scalar c2) = Scalar $ c1*c2
  (Scalar c) * (Pow u) = Pow $ c *> u
  (Scalar c) * (Dec u) = Dec $ c *> u
  (Scalar c) * (CRT u) = CRT $ c *> u
  (Scalar c1) * (Sub c2) = Sub $ Scalar c1 * c2

  (Pow u) * (Scalar c) = Pow $ c *> u
  (Dec u) * (Scalar c) = Dec $ c *> u
  (CRT u) * (Scalar c) = CRT $ c *> u
  (Sub c1) * (Scalar c2) = Sub $ c1 * Scalar c2

  -- TWO SUBS: work in a CRT rep for compositum
  (Sub (c1 :: Cyc t m1 r)) * (Sub (c2 :: Cyc t m2 r)) =
    -- re-wrap c1, c2 as Subs of the composition, and force them to CRT
    (Sub $ (toCRT' $ Sub c1 :: Cyc t (FLCM m1 m2) r) * toCRT' (Sub c2))
    \\ lcm2Divides (Proxy::Proxy m1) (Proxy::Proxy m2) (Proxy::Proxy m)

  -- ELSE: work in appropriate CRT rep
  c1 * c2 = toCRT' c1 * toCRT' c2

---------- Core cyclotomic operations ----------

advisePow, adviseDec, adviseCRT :: (Fact m, CElt t r) => Cyc t m r -> Cyc t m r
{-# INLINABLE advisePow #-}
{-# INLINABLE adviseDec #-}
{-# INLINABLE adviseCRT #-}

-- | Same as 'adviseCRT', but for the powerful-basis representation.
advisePow = toPow'

-- | Same as 'adviseCRT', but for the powerful-basis representation.
adviseDec = toDec'

-- | Yield an equivalent element that /may/ be in a CRT
-- representation.  This can serve as an optimization hint. E.g.,
-- call 'adviseCRT' prior to multiplying the same value by many
-- other values.
adviseCRT = toCRT'

-- | Multiply by the special element @g@ of the @m@th cyclotomic.
mulG :: (Fact m, CElt t r) => Cyc t m r -> Cyc t m r
{-# INLINABLE mulG #-}
mulG (Pow u) = Pow $ U.mulG u
mulG (Dec u) = Dec $ U.mulG u
mulG (CRT u) = CRT $ U.mulG u
mulG (Scalar r) = CRT $ U.mulG $ scalarCRT r
mulG (Sub c) = mulG $ embed' c   -- must go to full ring

-- | Divide by @g@, returning 'Nothing' if not evenly divisible.
-- WARNING: this implementation is not a constant-time algorithm, so
-- information about the argument may be leaked through a timing
-- channel.
divG :: (Fact m, CElt t r) => Cyc t m r -> Maybe (Cyc t m r)
{-# INLINABLE divG #-}
divG (Pow u) = Pow <$> U.divG u
divG (Dec u) = Dec <$> U.divG u
divG (CRT u) = CRT <$> U.divG u
divG (Scalar r) = CRT <$> U.divG (scalarCRT r)
divG (Sub c) = divG $ embed' c  -- must go to full ring

-- | Sample from the "tweaked" Gaussian error distribution @t*D@ in
-- the decoding basis, where @D@ has scaled variance @v@.  (Note: This
-- implementation uses Double precision to generate the Gaussian
-- sample, which may not be sufficient for rigorous proof-based
-- security.)
tGaussian :: (Fact m, OrdFloat q, Random q, Tensor t, TElt t q,
              ToRational v, MonadRandom rnd)
             => v -> rnd (Cyc t m q)
tGaussian = (Dec <$>) . U.tGaussian
{-# INLINABLE tGaussian #-}

-- | Yield the scaled squared norm of @g_m \cdot e@ under
-- the canonical embedding, namely,
-- @\hat{m}^{ -1 } \cdot || \sigma(g_m \cdot e) ||^2@ .
gSqNorm :: forall t m r . (Fact m, CElt t r) => Cyc t m r -> r
{-# INLINABLE gSqNorm #-}
gSqNorm (Pow u) = U.gSqNorm $ toDec u
gSqNorm (Dec u) = U.gSqNorm u
gSqNorm (CRT u) = U.gSqNorm $ toDec u
-- CJP: don't really need to do this: gSqNorm of scalar 1 is known.
gSqNorm (Scalar u) = U.gSqNorm (scalarDec u :: UCyc t m D r)
gSqNorm (Sub c) = U.gSqNorm (U.embedDec $ uncycDec c :: UCyc t m D r)

-- | Generate an LWE error term with given scaled variance,
-- deterministically rounded with respect to the decoding basis.
errorRounded :: (ToInteger z, Tensor t, Fact m, TElt t z,
                 ToRational v, MonadRandom rnd) => v -> rnd (Cyc t m z)
{-# INLINABLE errorRounded #-}
errorRounded = (Dec <$>) . U.errorRounded

-- | Generate an LWE error term with given scaled variance @* p^2@ over
-- the given coset, deterministically rounded with respect to the
-- decoding basis.
errorCoset ::
  (Mod zp, z ~ ModRep zp, Lift zp z, Fact m,
   CElt t zp, TElt t z, ToRational v, MonadRandom rnd)
  => v -> Cyc t m zp -> rnd (Cyc t m z)
errorCoset v = (Dec <$>) . U.errorCoset v . uncycDec
{-# INLINABLE errorCoset #-}

---------- Inter-ring operations ----------

-- | Embed (lazily) into an extension ring.
embed :: forall t m m' r . (m `Divides` m') => Cyc t m r -> Cyc t m' r
{-# INLINABLE embed #-}
embed (Scalar c) = Scalar c           -- keep as scalar
embed (Sub (c :: Cyc t l r)) = Sub c  -- keep as subring element
  \\ transDivides (Proxy::Proxy l) (Proxy::Proxy m) (Proxy::Proxy m')
embed c = Sub c

-- | Force to a non-'Sub' constructor (for internal use only).
embed' :: forall t r l m . (l `Divides` m, CElt t r) => Cyc t l r -> Cyc t m r
{-# INLINE embed' #-}
embed' (Pow u) = Pow $ embedPow u
embed' (Dec u) = Dec $ embedDec u
embed' (CRT u) = either Pow CRT $ embedCRT u
embed' (Scalar c) = Scalar c
embed' (Sub (c :: Cyc t k r)) = embed' c
  \\ transDivides (Proxy::Proxy k) (Proxy::Proxy l) (Proxy::Proxy m)

-- | The "tweaked trace" (twace) function
-- @Tw(x) = (mhat \/ m'hat) * Tr(g' \/ g * x)@,
-- which fixes @R@ pointwise (i.e., @twace . embed == id@).
twace :: forall t m m' r . (m `Divides` m', CElt t r)
         => Cyc t m' r -> Cyc t m r
{-# INLINABLE twace #-}
twace (Pow u) = Pow $ U.twacePow u
twace (Dec u) = Dec $ U.twaceDec u
twace (CRT u) = either Pow CRT $ twaceCRT u
twace (Scalar u) = Scalar u
twace (Sub (c :: Cyc t l r)) = Sub (twace c :: Cyc t (FGCD l m) r)
                               \\ gcdDivides (Proxy::Proxy l) (Proxy::Proxy m)

-- | Return the given element's coefficient vector with respect to
-- the (relative) powerful/decoding basis of the cyclotomic
-- extension @O_m' / O_m@.
coeffsCyc :: (m `Divides` m', CElt t r) => R.Basis -> Cyc t m' r -> [Cyc t m r]
{-# INLINABLE coeffsCyc #-}
coeffsCyc R.Pow c' = Pow <$> U.coeffsPow (uncycPow c')
coeffsCyc R.Dec c' = Dec <$> U.coeffsDec (uncycDec c')

-- | The relative powerful basis of @O_m' / O_m@.
powBasis :: (m `Divides` m', CElt t r) => Tagged m [Cyc t m' r]
powBasis = (Pow <$>) <$> U.powBasis
{-# INLINABLE powBasis #-}

-- | The relative mod-@r@ CRT set of the extension.
crtSet :: (m `Divides` m', ZPP r, CElt t r, TElt t (ZpOf r))
          => Tagged m [Cyc t m' r]
crtSet = (Pow <$>) <$> U.crtSet
{-# INLINABLE crtSet #-}


---------- Lattice operations and instances ----------

instance (Reduce a b, Fact m, CElt t a, CElt t b)
    -- CJP: need these specific constraints to get Reduce instance for Sub case
         => Reduce (Cyc t m a) (Cyc t m b) where
  {-# INLINABLE reduce #-}
  reduce (Pow u) = Pow $ reduce u
  reduce (Dec u) = Dec $ reduce u
  reduce (CRT u) = Pow $ reduce $ toPow u
  reduce (Scalar c) = Scalar $ reduce c
  reduce (Sub (c :: Cyc t l a)) = Sub (reduce c :: Cyc t l b)

type instance LiftOf (Cyc t m r) = Cyc t m (LiftOf r)

-- | Lift in the specified basis.
liftCyc :: (Lift b a, Fact m, TElt t a, CElt t b)
           => R.Basis -> Cyc t m b -> Cyc t m a
{-# INLINABLE liftCyc #-}

liftCyc R.Pow = liftPow
liftCyc R.Dec = liftDec

liftPow, liftDec :: (Lift b a, Fact m, TElt t a, CElt t b)
                    => Cyc t m b -> Cyc t m a
{-# INLINABLE liftPow #-}
{-# INLINABLE liftDec #-}
liftPow (Pow u) = Pow $ lift u
liftPow (Dec u) = Pow $ lift $ toPow u
liftPow (CRT u) = Pow $ lift $ toPow u
-- optimized for subrings; these are correct for powerful basis but
-- not for decoding
liftPow (Scalar c) = Scalar $ lift c
liftPow (Sub c) = Sub $ liftPow c

liftDec (Pow u) = Dec $ lift $ toDec u
liftDec (Dec u) = Dec $ lift u
liftDec (CRT u) = Dec $ lift $ toDec u
liftDec (Scalar c) = Dec $ lift $ scalarDec c
liftDec (Sub c) = liftDec $ embed' c

unzipCyc :: (Tensor t, Fact m) => Cyc t m (a,b) -> (Cyc t m a, Cyc t m b)
unzipCyc (Pow u) = Pow *** Pow $ U.unzipCyc u
unzipCyc (Dec u) = Dec *** Dec $ U.unzipCyc u
unzipCyc (CRT u) = CRT *** CRT $ U.unzipCyc u
unzipCyc (Scalar c) = Scalar *** Scalar $ c
unzipCyc (Sub c) = Sub *** Sub $ unzipCyc c

-- generic RescaleCyc instance

instance {-# OVERLAPS #-} (Rescale a b, CElt t a, TElt t b)
    => R.RescaleCyc (Cyc t) a b where

  -- Optimized for subring constructors, for powerful basis.
  -- Analogs for decoding basis are not quite correct, because (* -1)
  -- doesn't commute with 'rescale' due to tiebreakers!
  rescaleCyc R.Pow (Scalar c) = Scalar $ rescale c
  rescaleCyc R.Pow (Sub c) = Sub $ R.rescalePow c

  rescaleCyc R.Pow c = Pow $ fmapPow rescale $ uncycPow c
  rescaleCyc R.Dec c = Dec $ fmapDec rescale $ uncycDec c
  {-# INLINABLE rescaleCyc #-}

-- specialized instance for product rings: ~2x faster algorithm
instance (Mod a, Field b, Lift a (ModRep a), Reduce (LiftOf a) b,
         CElt t a, CElt t b, CElt t (LiftOf a))
         => R.RescaleCyc (Cyc t) (a,b) b where

  -- optimized for subrings and powerful basis (see comments in other
  -- instance for why this doesn't work for decoding basis)
  rescaleCyc R.Pow (Scalar c) = Scalar $ rescale c
  rescaleCyc R.Pow (Sub c) = Sub $ R.rescalePow c

  rescaleCyc bas c = let aval = proxy modulus (Proxy::Proxy a)
                         (a,b) = unzipCyc c
                         z = liftCyc bas a
                     in Scalar (recip (reduce aval)) * (b - reduce z)
  {-# INLINABLE rescaleCyc #-}


instance (Gadget gad zq, Fact m, CElt t zq) => Gadget gad (Cyc t m zq) where
  gadget = (scalarCyc <$>) <$> gadget
  -- specialization fo 'encode', done efficiently
  encode s = ((* adviseCRT s) <$>) <$> gadget

-- promote Decompose, using the powerful basis
instance (Decompose gad zq, Fact m, CElt t zq, CElt t (DecompOf zq))
         => Decompose gad (Cyc t m zq) where

  type DecompOf (Cyc t m zq) = Cyc t m (DecompOf zq)

  -- faster implementations: decompose directly in subring, which is
  -- correct because we decompose in powerful basis
  decompose (Scalar c) = pasteT $ Scalar <$> peelT (decompose c)
  decompose (Sub c) = pasteT $ Sub <$> peelT (decompose c)

  -- traverse: Traversable (UCyc t m P) and Applicative (Tagged gad ZL)
  decompose (Pow u) = fromZL $ Pow <$> traverse (toZL . decompose) u
  decompose c = decompose $ toPow' c

toZL :: Tagged s [a] -> TaggedT s ZipList a
toZL = coerce

fromZL :: TaggedT s ZipList a -> Tagged s [a]
fromZL = coerce

-- promote Correct, using the decoding basis
instance (Correct gad zq, Fact m, CElt t zq) => Correct gad (Cyc t m zq) where
  -- sequence: Monad [] and Traversable (UCyc t m D)
  -- sequenceA: Applicative (UCyc t m D) and Traversable (TaggedT gad [])
  correct bs = Dec *** (Dec <$>) $
               second sequence $ U.unzipCyc $ (correct . pasteT) <$>
               sequenceA (uncycDec <$> peelT bs)

---------- Change of representation (internal use only) ----------

toPow', toDec', toCRT' :: (Fact m, CElt t r) => Cyc t m r -> Cyc t m r
{-# INLINE toPow' #-}
{-# INLINE toDec' #-}
{-# INLINE toCRT' #-}

-- | Force to powerful-basis representation (for internal use only).
toPow' c@(Pow _) = c
toPow' (Dec u) = Pow $ toPow u
toPow' (CRT u) = Pow $ toPow u
toPow' (Scalar c) = Pow $ scalarPow c
toPow' (Sub c) = toPow' $ embed' c

-- | Force to decoding-basis representation (for internal use only).
toDec' (Pow u) = Dec $ toDec u
toDec' c@(Dec _) = c
toDec' (CRT u) = Dec $ toDec u
toDec' (Scalar c) = Dec $ scalarDec c
toDec' (Sub c) = toDec' $ embed' c

-- | Force to CRT representation (for internal use only).
toCRT' (Pow u) = CRT $ toCRT u
toCRT' (Dec u) = CRT $ toCRT u
toCRT' c@(CRT _) = c
toCRT' (Scalar c) = CRT $ scalarCRT c
-- CJP: below is the fastest algorithm for when both source and target
-- have the same CRTr/CRTe choice.  It is not the fastest when the
-- choices are different (it will do an unnecessary CRT if input is
-- non-CRT), but this is an unusual case.  Note: both toCRT' are
-- necessary in generaly, because embed' may not preserve CRT
-- representation!
toCRT' (Sub c) = toCRT' $ embed' $ toCRT' c

---------- Utility instances ----------

instance (Tensor t, Fact m, NFData r, TElt t r,
          NFData (CRTExt r), TElt t (CRTExt r)) => NFData (Cyc t m r) where
  rnf (Pow u) = rnf u
  rnf (Dec u) = rnf u
  rnf (CRT u) = rnf u
  rnf (Scalar u) = rnf u
  rnf (Sub c) = rnf c

instance (Random r, Tensor t, Fact m, CRTElt t r) => Random (Cyc t m r) where
  random g = let (u,g') = random g
             in (either Pow CRT u, g')
  {-# INLINABLE random #-}

  randomR _ = error "randomR non-sensical for Cyc"

instance (Arbitrary (UCyc t m P r)) => Arbitrary (Cyc t m r) where
  arbitrary = Pow <$> arbitrary
  shrink = shrinkNothing

instance (Show r, Show (CRTExt r), Tensor t, Fact m, TElt t r, TElt t (CRTExt r)) => Show (Cyc t m r) where
  show (Scalar c) = "Cyc Scalar: " ++ show c
  show (Pow u) = "Cyc: " ++ show u
  show (Dec u) = "Cyc: " ++ show u
  show (CRT u) = "Cyc: " ++ show u
  show (Sub c) = "Cyc Sub: " ++ show c
