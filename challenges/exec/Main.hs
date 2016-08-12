{-# LANGUAGE BangPatterns               #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses      #-}
{-# LANGUAGE RecordWildCards            #-}
{-# LANGUAGE ScopedTypeVariables        #-}

-- | Main module for the rlwe-challenges executable.

module Main where

import Control.Monad
import Data.Time.Clock.POSIX
import Options

import System.Console.ANSI
import System.Exit
import System.IO

import Beacon
import Common
import Generate
import Params
import Suppress
import Verify

-- extras
import           Control.DeepSeq
import           Control.Monad.CryptoRandom
import           Control.Monad.Except
import           Control.Monad.Identity
import           Control.Monad.IO.Class
import           Crypto.Lol.Types.Random
import qualified Data.Vector                as V
import qualified Data.Vector.Unboxed        as U
--import System.Random
import Control.Arrow
import Control.Monad.State.Strict as Strict

data MainOpts =
  MainOpts
  { optChallDir :: FilePath -- ^ location of challenges
  }

instance Options MainOpts where
  defineOptions = MainOpts <$>
    simpleOption "challenge-dir" "challenges/" "Path to challenges"

data GenOpts =
  GenOpts
  { optParamsFile      :: FilePath, -- ^ file with parameters for generation
    optNumInstances    :: InstanceID, -- ^ number of instances per challenge
    optInitBeaconEpoch :: BeaconEpoch -- ^ initial beacon epoch for suppress phase
  }

instance Options GenOpts where
  defineOptions = GenOpts <$>
    simpleOption "params" "params.txt" "File containing RLWE/R parameters" <*>
    simpleOption "num-instances" 32
    "Number N of instances per challenge, N = 2^k <= 256" <*>
    (defineOption optionType_int64 $ \o ->
      o {optionLongFlags = ["init-beacon"],
         optionDescription = "Initial beacon epoch for suppress phase."})

-- | Epoch that's @n@ days from now, rounded to a multiple of 60 for
-- NIST beacon purposes.
daysFromNow :: Int -> IO BeaconEpoch
daysFromNow n = do
  t <- round <$> getPOSIXTime
  return $ 86400 * fromIntegral n + t

data NullOpts = NullOpts

instance Options NullOpts where
  defineOptions = pure NullOpts

bar :: MonadCRandom e rnd => rnd Int
bar = go 1000000 0
  where go :: (MonadCRandom e rnd) => Int -> Int -> rnd Int
        go 0 !acc = return acc
        go n !acc = do
          !val <- getCRandom
          go (n-1) (acc+val)

-- CJP: experimental stuff starts here
newtype CRandT' g e m a = CRandT' { unCRandT' :: Strict.StateT g (ExceptT e m) a }
  deriving (Functor, Applicative, Monad, MonadIO, MonadError e, MonadFix)

type CRand' g e = CRandT' g e Identity

evalCRand' :: CRand' g GenError a -> g -> Either GenError a
evalCRand' m = runIdentity . evalCRandT' m
{-# INLINE evalCRand' #-}

evalCRandT' :: (ContainsGenError e, Monad m) => CRandT' g e m a -> g -> m (Either e a)
evalCRandT' m g = liftM (right fst) (runCRandT' m g)
{-# INLINE evalCRandT' #-}

runCRandT' :: ContainsGenError e => CRandT' g e m a -> g -> m (Either e (a,g))
runCRandT' m g = runExceptT . flip Strict.runStateT g . unCRandT' $ m
{-# INLINE runCRandT' #-}

instance (ContainsGenError e, Monad m, CryptoRandomGen g)
  => MonadCRandom e (CRandT' g e m) where
  getCRandom  = wrap crandom
  {-# INLINE getCRandom #-}
  getBytes i = wrap (genBytes i)
  {-# INLINE getBytes #-}
  getBytesWithEntropy i e = wrap (genBytesWithEntropy i e)
  {-# INLINE getBytesWithEntropy #-}
  doReseed bs = CRandT' $
    get >>= \g ->
      case reseed bs g of
        Right g' -> put g'
        Left  x  -> throwError (fromGenError x)
  {-# INLINE doReseed #-}

wrap :: (Monad m, ContainsGenError e) => (g -> Either GenError (a,g)) -> CRandT' g e m a
wrap f = CRandT' $ do
  g <- get
  case f g of
    Right (a,g') -> put g' >> return a
    Left x -> throwError (fromGenError x)
{-# INLINE wrap #-}

{-
main :: IO ()
main = print $ sum [(1::Int)..1000000]

-- homegrown replicateM variant
main :: IO ()
main = do
  g <- newGenIO
  let (Right y) = evalCRand (bar :: CRand InstDRBG GenError Int) g
  print y
-}

-- replicateM version
main :: IO ()
main = do
  g :: InstDRBG <- newGenIO
  -- NullDRBG: evalRand (lazy) takes 2.1s; evalCRand' (strict) takes 2.1s (no difference)

  -- CtrDRBG with []: evalCRand (lazy) 6.2s; evalCRand' (strict) 3.9s.
  --   (doesn't matter whether we deepseq xs before summing)
  -- CtrDRBG unboxed Vector: lazy and strict both 3.9s
  -- CtrDRBG   boxed Vector: lazy and strict both 3.9s
  let (Right y) = evalCRand' (do xs :: U.Vector Int <- U.replicateM 1000000 getCRandom
                                 return $ U.sum xs) g
  print y

{-  original
main :: IO ()
main = do
  -- for nice printing when running executable
  hSetBuffering stdout NoBuffering
  runSubcommand
    [ subcommand "generate" generate
    , subcommand "suppress" suppress
    , subcommand "verify" verify
    ]
-}

generate :: MainOpts -> GenOpts -> [String] -> IO ()
generate MainOpts{..} GenOpts{..} _ = do
  let initBeaconTime = beaconFloor optInitBeaconEpoch
      initBeacon = BA initBeaconTime 0
  when (initBeaconTime == 0) $ do
    putStrLn "You must specify the initial beacon time with --init-beacon"
    exitFailure
  currTime <- round <$> getPOSIXTime
  case initBeaconTime > currTime of
    True -> putStrLn $ "Challenges can be revealed starting at " ++
            show initBeaconTime ++ ", " ++ show (initBeaconTime-currTime) ++
            " seconds from now."
    False -> printANSI Yellow "WARNING: Reveal time is in the past!"
  paramContents <- readFile optParamsFile
  let params = parseChallParams paramContents optNumInstances
  generateMain optChallDir initBeacon params

suppress :: MainOpts -> NullOpts -> [String] -> IO ()
suppress MainOpts{..} _ _ = suppressMain optChallDir

verify :: MainOpts -> NullOpts -> [String] -> IO ()
verify MainOpts{..} _ _ = verifyMain optChallDir
