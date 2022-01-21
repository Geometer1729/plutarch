module Examples.PlutusType (AB (..), swap, tests) where

import Plutarch
import Plutarch.Bool (pif, (#==))
import Plutarch.Integer (PInteger)
import Plutarch.Lift (pconstant)

import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (testCase)

import Utils

{- |
  A Sum type, which can be encoded as an Enum
-}
data AB (s :: S) = A | B

{- |
  AB is encoded as an Enum, using values of PInteger
  internally.
-}
instance PlutusType AB where
  type PInner AB _ = PInteger

  pcon' A = pconstant 0
  pcon' B = pconstant 1

  pmatch' x f =
    pif (x #== pconstant 0) (f A) (f B)

{- |
  Instead of using `pcon'` and `pmatch'` directly,
  use 'pcon' and 'pmatch', to hide the `PInner` type.
-}
swap :: Term s AB -> Term s AB
swap x = pmatch x $ \case
  A -> pcon B
  B -> pcon A

tests :: HasTester => TestTree
tests =
  testGroup
    "PlutusType examples"
    [ testCase "A encoded as 0" $ do
        pcon A `equal` (pconstant 0 :: Term s PInteger)
    , testCase "B encoded as 2" $ do
        pcon B `equal` (pconstant 1 :: Term s PInteger)
    , testCase "swap A == B" $ do
        swap (pcon A) `equal` pcon B
    , testCase "swap B == A" $ do
        swap (pcon B) `equal` pcon A
    ]
