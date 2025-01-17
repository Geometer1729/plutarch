{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE UndecidableInstances #-}

module Plutarch.FieldSpec (spec) where

import Test.Syd
import Test.Tasty.HUnit

import qualified GHC.Generics as GHC
import Generics.SOP (Generic, I (I))
import Plutarch
import Plutarch.DataRepr (
  PDataFields,
  PIsDataReprInstances (PIsDataReprInstances),
 )
import Plutarch.Unsafe (punsafeBuiltin, punsafeCoerce)

import qualified PlutusCore as PLC
import qualified PlutusTx

import Plutarch.Prelude
import Plutarch.Test

spec :: Spec
spec = do
  describe "field" $ do
    -- example: Trips
    describe "trips" $ do
      -- compilation
      describe "tripSum" $ do
        golden All tripSum
      describe "getY" $ do
        golden All getY
      describe "tripYZ" $ do
        golden All tripYZ
      -- tests
      describe "tripSum # tripA = 1000" $ do
        let p = 1000
        it "works" $ plift (tripSum # tripA) @?= p
      describe "tripSum # tripB = 100" $ do
        let p = 100
        it "works" $ plift (tripSum # tripB) @?= p
      describe "tripSum # tripC = 10" $ do
        let p = 10
        it "works" $ plift (tripSum # tripC) @?= p
      describe "tripYZ = tripZY" $
        it "works" $ tripZY #@?= tripYZ
    -- rangeFields
    describe "rangeFields" $ do
      -- compilation
      describe "rangeFields" $ do
        golden All rangeFields
      -- tests
      describe "rangeFields someFields = 11" $ do
        let p = 11
        it "works" $ plift (rangeFields # someFields) @?= p
    -- dropFields
    describe "dropFields" $ do
      -- compilation
      describe "dropFields" $ do
        golden All dropFields
      -- tests
      describe "dropFields someFields = 17" $ do
        let p = 17
        it "works" $ plift (dropFields # someFields) @?= p
    -- pletFields
    describe "pletFields" $ do
      -- compilation
      describe "letSomeFields" $ do
        golden All letSomeFields
      describe "nFields" $ do
        golden All nFields
      -- tests
      describe "letSomeFields = letSomeFields'" $ do
        it "works" $ letSomeFields #@?= letSomeFields'
      describe "letSomeFields someFields = 14" $ do
        let p = 14
        it "works" $ plift (letSomeFields # someFields) @?= p
      describe "nFields someFields = 1" $ do
        let p = 1
        it "works" $ plift (nFields # someFields) @?= p
    describe "other" $ do
      -- tests
      describe "by = 10" $ do
        let p = 10
        it "works" $ plift by @?= p
      describe "dotPlus = 19010" $ do
        let p = 19010
        it "works" $ plift dotPlus @?= p

--------------------------------------------------------------------------------

{- |
  We can defined a data-type using PDataRecord, with labeled fields.

  With an appropriate instance of 'PIsDataRepr', we can automatically
  derive 'PDataFields'.
-}
newtype Triplet (a :: PType) (s :: S)
  = Triplet
      ( Term
          s
          ( PDataRecord
              '[ "x" ':= a
               , "y" ':= a
               , "z" ':= a
               ]
          )
      )
  deriving stock (GHC.Generic)
  deriving anyclass (Generic)
  deriving anyclass (PIsDataRepr)
  deriving
    (PlutusType, PIsData, PDataFields)
    via (PIsDataReprInstances (Triplet a))

mkTrip ::
  forall a s. (PIsData a) => Term s a -> Term s a -> Term s a -> Term s (Triplet a)
mkTrip x y z =
  punsafeBuiltin PLC.ConstrData # (0 :: Term _ PInteger)
    # ( ( pcons # (pdata x)
            #$ pcons # (pdata y)
            #$ pcons # (pdata z)
              # pnil
        ) ::
          Term _ (PBuiltinList (PAsData a))
      )

-- | An example term
tripA :: Term s (Triplet PInteger)
tripA = mkTrip 150 750 100

-- | Another
tripB :: Term s (Triplet PInteger)
tripB = mkTrip 50 10 40

-- | Another
tripC :: Term s (Triplet PInteger)
tripC = mkTrip 1 8 1

-- | Nested triplet
tripTrip :: Term s (Triplet (Triplet PInteger))
tripTrip = mkTrip tripA tripB tripC

{- |
  'pletFields' generates efficient bindings for the specified fields,
  as a 'HRec' of fields.

  The fields in the 'HRec' can them be accessed with
  RecordDotSyntax.
-}
tripSum :: Term s ((Triplet PInteger) :--> PInteger)
tripSum =
  plam $ \x -> pletFields @["x", "y", "z"] x $
    \fs ->
      pfromData fs.x
        + pfromData fs.y
        + pfromData fs.z

{- |
   A subset of fields can be specified.
-}
tripYZ :: Term s ((Triplet PInteger) :--> PInteger)
tripYZ =
  plam $ \x -> pletFields @["y", "z"] x $
    \fs ->
      pfromData fs.y + pfromData fs.z

{- |
  The ordering of fields specified is irrelevant,
  this is equivalent to 'tripYZ'.
-}
tripZY :: Term s ((Triplet PInteger) :--> PInteger)
tripZY =
  plam $ \x -> pletFields @["z", "y"] x $
    \fs ->
      pfromData fs.y + pfromData fs.z

{- |
  When accessing only a single field, we can use 'pfield'.

  This should be used carefully - if more than one field is needed,
  'pletFields' is more efficient.
-}
by :: Term s PInteger
by = pfield @"y" # tripB

getY :: Term s (Triplet PInteger :--> PAsData PInteger)
getY = pfield @"y"

{- |
  Due to the instance @(PDataFields a) -> PDataFields (PAsData a)@,

  we can conveniently chain 'pletAllFields' & 'pfield' within
  nested structures:
-}
dotPlus :: Term s PInteger
dotPlus =
  pletFields @["x", "y", "z"] tripTrip $ \ts ->
    pletFields @["x", "y", "z"] (ts.x) $ \a ->
      pletFields @["x", "y", "z"] (ts.y) $ \b ->
        pletFields @["x", "y", "z"] (ts.z) $ \c ->
          (pfromData a.x * pfromData b.x)
            + (pfromData a.y * pfromData b.y)
            + (pfromData a.z * pfromData b.z)
            + pfromData c.x
            + pfromData c.y
            + pfromData c.z

type SomeFields =
  '[ "_0" ':= PInteger
   , "_1" ':= PInteger
   , "_2" ':= PInteger
   , "_3" ':= PInteger
   , "_4" ':= PInteger
   , "_5" ':= PInteger
   , "_6" ':= PInteger
   , "_7" ':= PInteger
   , "_8" ':= PInteger
   , "_9" ':= PInteger
   ]

someFields :: Term s (PDataRecord SomeFields)
someFields =
  punsafeCoerce $
    pconstant $
      fmap (PlutusTx.toData @Integer) [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]

{- |
  We can also bind over a 'PDataRecord' directly.
-}
nFields :: Term s (PDataRecord SomeFields :--> PInteger)
nFields =
  plam $ \r -> pletFields @["_0", "_1"] r $ \fs ->
    pfromData fs._0
      + pfromData fs._1

dropFields :: Term s (PDataRecord SomeFields :--> PInteger)
dropFields =
  plam $ \r -> pletFields @["_8", "_9"] r $ \fs ->
    pfromData fs._8
      + pfromData fs._9

rangeFields :: Term s (PDataRecord SomeFields :--> PInteger)
rangeFields =
  plam $ \r -> pletFields @["_5", "_6"] r $ \fs ->
    pfromData fs._5
      + pfromData fs._6

{- |
  'pletFields' makes it convenient to pick out
  any amount of desired fields, efficiently.
-}
letSomeFields :: Term s (PDataRecord SomeFields :--> PInteger)
letSomeFields =
  plam $ \r -> pletFields @["_3", "_4", "_7"] r $ \fs ->
    pfromData fs._3
      + pfromData fs._4
      + pfromData fs._7

{- |
  Ordering of fields is irrelevant
-}
letSomeFields' :: Term s (PDataRecord SomeFields :--> PInteger)
letSomeFields' =
  plam $ \r -> pletFields @["_7", "_3", "_4"] r $ \fs ->
    pfromData fs._3
      + pfromData fs._4
      + pfromData fs._7
