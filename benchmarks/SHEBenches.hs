{-# LANGUAGE ConstraintKinds, DataKinds, FlexibleContexts, FlexibleInstances, GADTs, 
             MultiParamTypeClasses, NoImplicitPrelude, RankNTypes, RebindableSyntax, 
             ScopedTypeVariables, TypeFamilies, TypeOperators, UndecidableInstances #-}

module SHEBenches (sheBenches) where

import Criterion
import Utils

import Control.Applicative
import Control.DeepSeq
import Control.Monad.Random
import Control.Monad.State
import Control.Monad.Trans.State (StateT, evalStateT)
import Crypto.Lol.Types.Random
import Crypto.Random.DRBG

import Crypto.Lol hiding (CT)
import qualified Crypto.Lol.Cyclotomic.Tensor.CTensor as CT
import Crypto.Lol.Applications.SymmSHE

import Data.Singletons
import Data.Promotion.Prelude.List
import Data.Promotion.Prelude.Eq
import Data.Singletons.TypeRepStar

sheBenches :: (MonadRandom rnd) => rnd Benchmark
sheBenches = bgroupRnd "SHE" [
   bgroupRnd "encrypt"   $ benchEnc    $ wrapEnc bench_enc,
   bgroupRnd "*"         $ benchCTFunc $ wrapMul bench_mul,
   bgroupRnd "addPublic" $ benchCTFunc $ wrapPublic bench_addPublic,
   bgroupRnd "mulPublic" $ benchCTFunc $ wrapPublic bench_mulPublic,
   bgroupRnd "rescaleCT" $ benchZq'    $ wrapRescale bench_rescaleCT,
   bgroupRnd "keySwitch" $ benchKSQ    $ wrapKSQ bench_keySwQ
   ]

bench_enc :: forall t m m' z zp zq gen . (EncryptCtx t m m' z zp zq, CryptoRandomGen gen)
  => Proxy gen -> Proxy zq -> SK (Cyc t m' z) -> PT (Cyc t m zp) -> Benchmarkable
bench_enc _ _ sk pt = nfIO $ do
  gen <- newGenIO
  return $ evalRand (encrypt sk pt :: Rand (CryptoRand gen) (CT m zp (Cyc t m' zq))) gen

bench_mul :: (Ring (CT m zp (Cyc t m' zq)), NFData (CT m zp (Cyc t m' zq)))
  => CT m zp (Cyc t m' zq) -> CT m zp (Cyc t m' zq) -> Benchmarkable
bench_mul a = nf (*a)

bench_addPublic :: (AddPublicCtx t m m' zp zq) => Cyc t m zp -> CT m zp (Cyc t m' zq) -> Benchmarkable
bench_addPublic a ct = nf (addPublic a) ct

bench_mulPublic :: (MulPublicCtx t m m' zp zq) => Cyc t m zp -> CT m zp (Cyc t m' zq) -> Benchmarkable
bench_mulPublic a ct = nf (mulPublic a) ct

-- requires zq to be Liftable
bench_dec :: (DecryptCtx t m m' z zp zq) => SK (Cyc t m' z) -> CT m zp (Cyc t m' zq) -> Benchmarkable
bench_dec sk ct = nf (decrypt sk) ct

bench_rescaleCT :: forall t m m' zp zq zq' . 
  (RescaleCyc (Cyc t) zq' zq, ToSDCtx t m' zp zq', NFData (CT m zp (Cyc t m' zq)))
  => Proxy zq -> CT m zp (Cyc t m' zq') -> Benchmarkable
bench_rescaleCT _ = nf (rescaleLinearCT :: CT m zp (Cyc t m' zq') -> CT m zp (Cyc t m' zq))

bench_keySwQ :: (Ring (CT m zp (Cyc t m' zq)), NFData (CT m zp (Cyc t m' zq))) 
  => KSHint m zp t m' zq gad zq' -> CT m zp (Cyc t m' zq) -> Benchmarkable
bench_keySwQ (KeySwitch kswq) x = nf kswq $ x*x


data CTCtxD
-- union of compatible constraints in benchmarks
type CTCtx t m m' zp zq = 
  (EncryptCtx t m m' (LiftOf zp) zp zq,
   Ring (CT m zp (Cyc t m' zq)),
   NFData (CT m zp (Cyc t m' zq)),
   AddPublicCtx t m m' zp zq,
   MulPublicCtx t m m' zp zq,
   Show (BenchArgs '(t,m,m',zp,zq)))
data instance ArgsCtx CTCtxD where
  CTD :: (CTCtx t m m' zp zq) 
      => Proxy '(t,m,m',zp,zq) -> ArgsCtx CTCtxD
hideCT :: (forall t m m' zp zq . (CTCtx t m m' zp zq) 
  => Proxy '(t,m,m',zp,zq) -> rnd Benchmark) -> ArgsCtx CTCtxD -> rnd Benchmark
hideCT f (CTD p) = f p

instance (Run CTCtxD params, CTCtx t m m' zp zq) 
  => Run CTCtxD ( '(t, '(m,m',zp,zq)) ': params) where
  runAll _ f = (f $ CTD (Proxy::Proxy '(t,m,m',zp,zq))) : (runAll (Proxy::Proxy params) f)

wrapEnc :: (WrapCtx t m m' zp zq rnd bnch,
   bnch ~ (SK (Cyc t m' (LiftOf zp)) -> PT (Cyc t m zp) -> Benchmarkable))
  => (Proxy gen -> Proxy zq -> bnch)
     -> Proxy gen -> Proxy '(t,m,m',zp,zq) -> rnd Benchmark
wrapEnc f _ p = bench (showProxy p) <$> (genSHEArgs p $ f Proxy Proxy)

wrapMul :: (WrapCtx t m m' zp zq rnd bnch,
  bnch ~ (CT m zp (Cyc t m' zq) -> CT m zp (Cyc t m' zq) -> Benchmarkable))
  => bnch -> Proxy '(t, m, m', zp, zq) -> rnd Benchmark
wrapMul f p = bench (showProxy p) <$> genSHEArgs p f

wrapPublic :: (WrapCtx t m m' zp zq rnd bnch,
  bnch ~ (Cyc t m zp -> CT m zp (Cyc t m' zq) -> Benchmarkable))
  => bnch -> Proxy '(t,m,m',zp,zq) -> rnd Benchmark
wrapPublic f p = bench (showProxy p) <$> genSHEArgs p f

benchCTFunc :: (forall t m m' zp zq . (CTCtx t m m' zp zq) 
  => Proxy '(t,m,m',zp,zq) -> rnd Benchmark)
    -> [rnd Benchmark]
benchCTFunc g = runAll (Proxy::Proxy CTParams) $ hideCT g

benchEnc :: (Monad rnd)
  => (forall t m m' zp zq gen . (CTCtx t m m' zp zq, CryptoRandomGen gen) 
        => Proxy gen -> Proxy '(t,m,m',zp,zq) -> rnd Benchmark)
     -> [rnd Benchmark]
benchEnc g = [
  bgroupRnd "HashDRBG" $ benchCTFunc $ g (Proxy::Proxy HashDRBG),
  bgroupRnd "SysRand"  $ benchCTFunc $ g (Proxy::Proxy SystemRandom)]



data DecCtxD
type DecCtx t m m' zp zq = 
  (DecryptCtx t m m' (LiftOf zp) zp zq,
   Show (BenchArgs '(t,m,m',zp,zq)))
data instance ArgsCtx DecCtxD where
  DecD :: (DecCtx t m m' zp zq) 
      => Proxy '(t,m,m',zp,zq) -> ArgsCtx DecCtxD
hideDec:: (forall t m m' zp zq . (DecCtx t m m' zp zq) 
  => Proxy '(t,m,m',zp,zq) -> rnd Benchmark) -> ArgsCtx DecCtxD -> rnd Benchmark
hideDec f (DecD p) = f p

instance (Run DecCtxD params, DecCtx t m m' zp zq) 
  => Run DecCtxD ( '(t, '(m,m',zp,zq)) ': params) where
  runAll _ f = (f $ DecD (Proxy::Proxy '(t, m,m',zp,zq))) : (runAll (Proxy::Proxy params) f)

wrapDec ::(WrapCtx t m m' zp zq rnd bnch,
   bnch ~ (SK (Cyc t m' (LiftOf zp)) -> CT m zp (Cyc t m' zq) -> Benchmarkable))
  => bnch -> Proxy '(t, m, m', zp, zq) -> rnd Benchmark
wrapDec f p = bench (showProxy p) <$> genSHEArgs p f

benchDec :: (forall t m m' zp zq . (DecCtx t m m' zp zq) 
        => Proxy '(t,m,m',zp,zq) -> rnd Benchmark)
     -> [rnd Benchmark]
benchDec g = runAll (Proxy::Proxy DecParams) $ hideDec g



data Zq'CtxD
type Zq'Ctx t m m' zp zq zq' = 
  (EncryptCtx t m m' (LiftOf zp) zp zq',
   Show (BenchArgs '(t,m,m',zp,zq)),
   RescaleCyc (Cyc t) zq' zq,
   NFData (CT m zp (Cyc t m' zq)),
   ToSDCtx t m' zp zq')

data instance ArgsCtx Zq'CtxD where
  Zq'D :: (Zq'Ctx t m m' zp zq zq') 
      => Proxy '(t,m,m',zp,zq,zq') -> ArgsCtx Zq'CtxD
hideZq':: (forall t m m' zp zq zq' . (Zq'Ctx t m m' zp zq zq') 
  => Proxy '(t,m,m',zp,zq,zq') -> rnd Benchmark) -> ArgsCtx Zq'CtxD -> rnd Benchmark
hideZq' f (Zq'D p) = f p

instance (Run Zq'CtxD params, Zq'Ctx t m m' zp zq zq') 
  => Run Zq'CtxD ( '(t, '(m,m',zp,zq,zq')) ': params) where
  runAll _ f = (f $ Zq'D (Proxy::Proxy '(t,m,m',zp,zq,zq'))) : (runAll (Proxy::Proxy params) f)

wrapRescale :: forall t m m' zp zq zq' rnd bnch . (WrapCtx t m m' zp zq rnd bnch,
  bnch ~ (CT m zp (Cyc t m' zq') -> Benchmarkable))
  => (Proxy zq -> bnch) -> Proxy '(t,m,m',zp,zq,zq') -> rnd Benchmark
wrapRescale f _ = 
  let p = Proxy::Proxy '(t,m,m',zp,zq)
  in bench (showProxy p) <$> genSHEArgs p (f Proxy)

benchZq' :: 
  (forall t m m' zp zq zq' . 
    (Zq'Ctx t m m' zp zq zq') 
    => Proxy '(t,m,m',zp,zq,zq') -> rnd Benchmark)
  -> [rnd Benchmark]
benchZq' g = runAll (Proxy::Proxy Zq'Params) $ hideZq' g


data KSQCtxD
type KSQCtx t m m' zp zq zq' gad = 
  (EncryptCtx t m m' (LiftOf zp) zp zq,
   KeySwitchCtx gad t m' zp zq zq',
   KSHintCtx gad t m' (LiftOf zp) zq',
   -- ^ these provide the context to generate the parameters
   Ring (CT m zp (Cyc t m' zq)),
   NFData (CT m zp (Cyc t m' zq)),
   Show (BenchArgs '(t,m,m',zp,zq)))

data instance ArgsCtx KSQCtxD where
  KSQD :: (KSQCtx t m m' zp zq zq' gad) 
      => Proxy '(t,m,m',zp,zq,zq',gad) -> ArgsCtx KSQCtxD
hideKSQ:: (forall t m m' zp zq zq' gad . (KSQCtx t m m' zp zq zq' gad) 
  => Proxy '(t,m,m',zp,zq,zq',gad) -> rnd Benchmark) -> ArgsCtx KSQCtxD -> rnd Benchmark
hideKSQ f (KSQD p) = f p

instance (Run KSQCtxD params, KSQCtx t m m' zp zq zq' gad) 
  => Run KSQCtxD ( '(gad, '(t, '(m,m',zp,zq,zq'))) ': params) where
  runAll _ f = (f $ KSQD (Proxy::Proxy '(t,m,m',zp,zq,zq',gad))) : (runAll (Proxy::Proxy params) f)

wrapKSQ :: forall t m m' zp zq zq' gad rnd bnch . (WrapCtx t m m' zp zq rnd bnch,
  bnch ~ (KSHint m zp t m' zq gad zq' -> CT m zp (Cyc t m' zq) -> Benchmarkable))
  => bnch -> Proxy '(t,m,m',zp,zq,zq',gad) -> rnd Benchmark
wrapKSQ f _ = 
  let p = Proxy::Proxy '(t,m,m',zp,zq)
  in bench (showProxy p) <$> genSHEArgs p f

benchKSQ :: 
  (forall t m m' zp zq zq' gad . 
    (KSQCtx t m m' zp zq zq' gad) 
    => Proxy '(t,m,m',zp,zq,zq',gad) -> rnd Benchmark)
  -> [rnd Benchmark]
benchKSQ g = runAll (Proxy::Proxy KSQParams) $ hideKSQ g








-- sanity check: should take as long as the sum of its component tests
bench_mulCycle :: forall gad z zp zq zq' zq'' t m m' . (
                   Ring (CT m zp (Cyc t m' zq')), NFData (CT m zp (Cyc t m' zq)),
                   RescaleCyc (Cyc t) zq' zq, ToSDCtx t m' zp zq', z~ModRep zp,
                   KeySwitchCtx gad t m' zp zq' zq'') 
  => Proxy zq
     -> KSHint m zp t m' zq' gad zq''
     -> CT m zp (Cyc t m' zq')
     -> CT m zp (Cyc t m' zq')
     -> Benchmarkable
bench_mulCycle _ (KeySwitch kswq) a b = 
  nf (rescaleLinearCT . kswq . (a*) :: CT m zp (Cyc t m' zq') -> CT m zp (Cyc t m' zq)) b













type Gadgets = '[TrivGad, BaseBGad 2]
type Tensors = '[CT.CT,RT]
type MM'PQQ'Combos = 
  '[ '(F4, F128, Zq 64, Zq 257, Zq (257 ** 641)),
     '(F12, F32 * F9, Zq 64, Zq 577, Zq (577 ** 1153)),
     '(F12, F32 * F9, Zq 64, Zq (577 ** 1153), Zq (577 ** 1153 ** 2017)),
     '(F12, F32 * F9, Zq 64, Zq (577 ** 1153 ** 2017), Zq (577 ** 1153 ** 2017 ** 2593)),
     '(F12, F32 * F9, Zq 64, Zq (577 ** 1153 ** 2017 ** 2593), Zq (577 ** 1153 ** 2017 ** 2593 ** 3169)),
     '(F12, F32 * F9, Zq 64, Zq (577 ** 1153 ** 2017 ** 2593 ** 3169), Zq (577 ** 1153 ** 2017 ** 2593 ** 3169 ** 3457)),
     '(F12, F32 * F9, Zq 64, Zq (577 ** 1153 ** 2017 ** 2593 ** 3169 ** 3457), Zq (577 ** 1153 ** 2017 ** 2593 ** 3169 ** 3457 ** 6337)),
     '(F12, F32 * F9, Zq 64, Zq (577 ** 1153 ** 2017 ** 2593 ** 3169 ** 3457 ** 6337), Zq (577 ** 1153 ** 2017 ** 2593 ** 3169 ** 3457 ** 6337 ** 7489)),
     '(F12, F32 * F9 * F25, Zq 64, Zq 14401, Zq (14401 ** 21601))
    ]

data RemoveZq' :: TyFun (Factored, Factored, *, *, *) (Factored, Factored, *, *) -> *
type instance Apply RemoveZq' '(m,m',zp,zq,zq') = '(m,m',zp,zq)

data Liftable :: TyFun (Factored, Factored, *, *) Bool -> *
type instance Apply Liftable '(m,m',zp,zq) = Int64 :== (LiftOf zq)

type CTParams = ( '(,) <$> Tensors) <*> (Nub (Map RemoveZq' MM'PQQ'Combos))
type DecParams = ( '(,) <$> Tensors) <*> (Nub (Filter Liftable (Map RemoveZq' MM'PQQ'Combos)))
type Zq'Params = ( '(,) <$> Tensors) <*> MM'PQQ'Combos
type KSQParams = ( '(,) <$> Gadgets) <*> Zq'Params





type family SKOf bnch where
  SKOf (CT m zp (Cyc t m' zq) -> a) = SK (Cyc t m' (LiftOf zp))
  SKOf (SK (Cyc t m' z) -> a) = SK (Cyc t m' z)
  SKOf (KSHint m zp t m' zq gad zq' -> a) = SK (Cyc t m' (LiftOf zp))
  SKOf (a -> b) = SKOf b
type WrapCtx (t :: Factored -> * -> *) (m :: Factored) (m' :: Factored) zp zq rnd bnch = 
  (Monad rnd, Show (BenchArgs '(t,m,m',zp,zq)), GenArgs (StateT (Maybe (SKOf bnch)) rnd) bnch)


genSHEArgs :: forall t (m :: Factored) m' z zp zq bnch rnd . 
  (z ~ LiftOf zp, GenArgs (StateT (Maybe (SK (Cyc t m' z))) rnd) bnch, Monad rnd) 
  => Proxy '(t,m,m',zp,zq) -> bnch -> rnd Benchmarkable
genSHEArgs _ f = evalStateT (genArgs f) (Nothing :: Maybe (SK (Cyc t m' z)))

-- generates a secrete key with svar=1, using non-cryptographic randomness
instance (GenSKCtx t m z Double, 
          MonadRandom rnd, 
          MonadState (Maybe (SK (Cyc t m z))) rnd)
  => GenArg rnd (SK (Cyc t m z)) where
  genArg = do
    msk <- get
    sk <- case msk of
      Just sk -> return sk
      Nothing -> do
        sk <- genSK (1 :: Double)
        put $ Just sk
        return sk
    return sk

instance (EncryptCtx t m m' z zp zq,
          z ~ LiftOf zp,
          MonadRandom rnd,
          GenArg rnd (SK (Cyc t m' z)),
          GenArg rnd (Cyc t m zp)) 
  => GenArg rnd (CT m zp (Cyc t m' zq)) where
  genArg = do
    sk :: SK (Cyc t m' z) <- genArg
    pt <- genArg
    encrypt sk pt

newtype KSHint m zp t m' zq gad zq' = KeySwitch (CT m zp (Cyc t m' zq) -> CT m zp (Cyc t m' zq))
instance (GenArg rnd (SK (Cyc t m' z)),
          z ~ LiftOf zp,
          KeySwitchCtx gad t m' zp zq zq',
          KSHintCtx gad t m' z zq', 
          MonadRandom rnd)
  => GenArg rnd (KSHint m zp t m' zq gad zq') where
  genArg = do
    sk :: SK (Cyc t m' z) <- genArg
    KeySwitch <$> proxyT (keySwitchQuadCirc sk) (Proxy::Proxy (gad,zq'))
