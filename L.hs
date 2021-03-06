{-# LANGUAGE FlexibleInstances #-}

-- |Default load file for the Mueval plugin. Imports and definitions
-- can be added to this file to make them available to evaluated
-- expressions.
module L where

-- Use more generic versions of things
import Prelude hiding ( (.), id -- Control.Category
                      , foldr, foldr', foldl, foldl', foldr1, foldl1
                      , and, or, any, all, sum, product
                      , maximum, maximumBy, minimum, minimumBy
                      , concat, concatMap, elem, notElem, find -- Data.Foldable
                      , mapAccumL, mapAccumR, mapM, sequence, forM -- Data.Traversable
                      )

import Control.Applicative
import Control.Arrow
import Control.Category
import Control.Exception
import Control.Lens
import Control.Monad hiding (mapM, sequence, forM) -- clash with Data.Traversable
import Control.Monad.Fix hiding (fix)
import Control.Monad.Zip

import Data.Bits
import Data.Bool
import Data.Char
import Data.Complex
import Data.Data
import Data.Data.Lens
import Data.Dynamic
import Data.Either
import Data.Eq
import Data.Fixed
import Data.Foldable
import Data.Function hiding ((.), id)
import Data.Functor
import Data.Int
import Data.Ix
import Data.List hiding ( concat, concatMap
                        , foldl, foldl', foldl1, foldr, foldr1
                        , and, or, any, all, sum, product
                        , maximum, maximumBy, minimum, minimumBy
                        , elem, notElem, find -- clash with Data.Foldable
                        , mapAccumL, mapAccumR) -- clash with Data.Traversable
import qualified Data.Map
import Data.Maybe
import Data.Monoid
import Data.Ord
import Data.Ratio
import Data.Sequence (Seq, ViewL(..), ViewR(..), viewl, viewr)
import qualified Data.Sequence as S
import qualified Data.Set
import Data.String
import Data.Time
import Data.Traversable
import Data.Tuple
import Data.Typeable
import Data.Unique
import Data.Version
import Data.Word

import Numeric

import System.Random

import qualified Test.LeanCheck  as LeanCheck
import qualified Test.QuickCheck as QuickCheck
import qualified Test.SmallCheck as SmallCheck

newtype NQString = NQString String

instance Show NQString where
  show (NQString str) = str

instance Show (IO ()) where
  show _ = "<IO ()>"

-- this is necessary for the mueval plugin's "check" command.
check :: LeanCheck.Testable prop => prop -> NQString
check = checkFor 100

checkFor :: LeanCheck.Testable prop => Int -> prop -> NQString
checkFor lim prop = NQString $
  let results  = zip [1..] . take lim $ LeanCheck.results prop
      failures = filter (\(_, (_, b)) -> not b) results
  in case listToMaybe failures of
    Just (1, (vs, _)) -> "*** Failed! Falsifiable (after 1 test): "                 ++ show vs
    Just (i, (vs, _)) -> "*** Failed! Falsifiable (after " ++ show i ++ " tests): " ++ show vs
    Nothing -> "+++ OK, passed " ++ show lim ++ " tests."
