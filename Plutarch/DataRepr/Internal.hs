{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans -Wno-redundant-constraints #-}

module Plutarch.DataRepr.Internal (
  PDataSum,
  punDataRepr,
  pindexDataRepr,
  pmatchDataRepr,
  DataReprHandlers (..),
  PDataRecord,
  PLabeledType (..),
  type PUnLabel,
  type PLabel,
  pdhead,
  pdtail,
  PIsDataRepr (..),
  PIsDataReprInstances (..),
  pindexDataRecord,
  pdropDataRecord,
  DerivePConstantViaData (..),
  GetPDataRecordArgs,
) where

import Data.Fin
import Data.List (groupBy, maximumBy, sortOn)
import GHC.TypeLits (ErrorMessage (Text), KnownNat, Symbol, TypeError, natVal)
import Generics.SOP
import Numeric.Natural (Natural)
import Plutarch (Dig, PMatch, TermCont, hashOpenTerm, punsafeBuiltin, punsafeCoerce, runTermCont)
import Plutarch.Bool (pif, (#==))
import Plutarch.Builtin (
  PAsData,
  PBuiltinList,
  PData,
  PIsData,
  pasConstr,
  pdata,
  pfromData,
  pfstBuiltin,
  psndBuiltin,
 )
import Plutarch.DataRepr.Internal.HList (type Drop, type IndexList)
import Plutarch.Generic
import Plutarch.Integer (PInteger)
import Plutarch.Internal (S (SI))
import Plutarch.Lift (PConstant, PConstantRepr, PConstanted, PLift, pconstantFromRepr, pconstantToRepr)
import Plutarch.List (pdrop, punsafeIndex)
import Plutarch.Prelude
import qualified Plutus.V1.Ledger.Api as Ledger
import qualified PlutusCore as PLC

data PDataRecord (as :: [PLabeledType]) (s :: S)

data PLabeledType = Symbol := PType

type family GetPDataRecordArgs (a :: [[Type]]) :: [[PLabeledType]] where
  GetPDataRecordArgs xs = ToPLabeled2 xs

type ToPLabeled :: [Type] -> [PLabeledType]
type family ToPLabeled as where
  ToPLabeled '[] = '[]
  ToPLabeled '[Term s (PDataRecord fs)] = fs
  ToPLabeled '[_] = TypeError ( 'Text "Expected PDataRecord")
  ToPLabeled _ = TypeError ( 'Text "Must have 0 or 1 argument in sum constructor")

-- Unfortunately we can't write a generic FMap due to ghc's arity limitations.
type ToPLabeled2 :: [[Type]] -> [[PLabeledType]]
type family ToPLabeled2 as where
  ToPLabeled2 '[] = '[]
  ToPLabeled2 (a ': as) = ToPLabeled a ': ToPLabeled2 as

pdhead :: Term s (PDataRecord ((l ':= a) : as) :--> PAsData a)
pdhead = phoistAcyclic $ pforce $ punsafeBuiltin PLC.HeadList

pdtail :: Term s (PDataRecord (a ': as) :--> PDataRecord as)
pdtail = phoistAcyclic $ pforce $ punsafeBuiltin PLC.TailList

type family PUnLabel (as :: [PLabeledType]) :: [PType] where
  PUnLabel '[] = '[]
  PUnLabel ((l ':= t) ': as) = t ': (PUnLabel as)

type family PLabel (as :: [PLabeledType]) :: [Symbol] where
  PLabel '[] = '[]
  PLabel ((l ':= t) ': as) = l ': (PLabel as)

type PDataSum :: [[PLabeledType]] -> PType
data PDataSum (defs :: [[PLabeledType]]) (s :: S)

pasData :: Term s (PDataSum _) -> Term s PData
pasData = punsafeCoerce

punDataRepr :: Term s (PDataSum '[def] :--> PDataRecord def)
punDataRepr = phoistAcyclic $
  plam $ \t ->
    plet (pasConstr #$ pasData t) $ \d ->
      (punsafeCoerce $ psndBuiltin # d :: Term _ (PDataRecord def))

pindexDataRepr :: (KnownNat n) => Proxy n -> Term s (PDataSum (def : defs) :--> PDataRecord (IndexList n (def : defs)))
pindexDataRepr n = phoistAcyclic $
  plam $ \t ->
    plet (pasConstr #$ pasData t) $ \d ->
      let i :: Term _ PInteger = pfstBuiltin # d
       in pif
            (i #== fromInteger (natVal n))
            (punsafeCoerce $ psndBuiltin # d :: Term _ (PDataRecord _))
            perror

-- | Safely index a 'PDataRecord'
pindexDataRecord :: (KnownNat n) => Proxy n -> Term s (PDataRecord xs) -> Term s (PAsData (IndexList n (PUnLabel xs)))
pindexDataRecord n xs =
  punsafeCoerce $
    punsafeIndex @PBuiltinList @PData ind (punsafeCoerce xs)
  where
    ind :: Natural
    ind = fromInteger $ natVal n

-- | Safely drop the first n items of a PDataRecord.
pdropDataRecord :: (KnownNat n) => Proxy n -> Term s (PDataRecord xs) -> Term s (PDataRecord (Drop n xs))
pdropDataRecord n xs =
  punsafeCoerce $
    pdrop @PBuiltinList @PData ind (punsafeCoerce xs)
  where
    ind :: Natural
    ind = fromInteger $ natVal n

data DataReprHandlers (out :: PType) (defs :: [[PLabeledType]]) (s :: S) where
  DRHNil :: DataReprHandlers out '[] s
  DRHCons :: (Term s (PDataRecord def) -> Term s out) -> DataReprHandlers out defs s -> DataReprHandlers out (def : defs) s

pmatchDataRepr :: Term s (PDataSum defs) -> DataReprHandlers out defs s -> Term s out
pmatchDataRepr d handlers =
  plet (pasConstr #$ pasData d) $ \d' ->
    plet (pfstBuiltin # d') $ \constr ->
      plet (psndBuiltin # d') $ \args ->
        let handlers' = applyHandlers args handlers
         in runTermCont (findCommon handlers') $ \common ->
              go
                common
                0
                handlers'
                constr
  where
    hashHandlers :: [Term s out] -> TermCont s [(Dig, Term s out)]
    hashHandlers [] = pure []
    hashHandlers (handler : rest) = do
      hash <- hashOpenTerm handler
      hashes <- hashHandlers rest
      pure $ (hash, handler) : hashes

    findCommon :: [Term s out] -> TermCont s (Dig, Term s out)
    findCommon handlers = do
      l <- hashHandlers handlers
      pure $ head . maximumBy (\x y -> length x `compare` length y) . groupBy (\x y -> fst x == fst y) . sortOn fst $ l

    applyHandlers :: Term s (PBuiltinList PData) -> DataReprHandlers out defs s -> [Term s out]
    applyHandlers _ DRHNil = []
    applyHandlers args (DRHCons handler rest) = handler (punsafeCoerce args) : applyHandlers args rest

    go ::
      (Dig, Term s out) ->
      Integer ->
      [Term s out] ->
      Term s PInteger ->
      Term s out
    go common _ [] _ = snd common
    go common idx (handler : rest) constr =
      runTermCont (hashOpenTerm handler) $ \hhash ->
        if hhash == fst common
          then go common (idx + 1) rest constr
          else
            pif
              (fromInteger idx #== constr)
              handler
              $ go common (idx + 1) rest constr

newtype PIsDataReprInstances (a :: PType) (s :: S) = PIsDataReprInstances (a s)

class (PMatch a, PIsData a) => PIsDataRepr (a :: PType) where
  type PIsDataReprRepr a :: [[PLabeledType]]
  type PIsDataReprRepr a = GetPDataRecordArgs (Code (a 'SI))
  pmatchDataReprHandlers :: forall s out. (a s -> Term s out) -> DataReprHandlers out (PIsDataReprRepr a) s
  default pmatchDataReprHandlers ::
    forall s out.
    ( ToPLabeled2 (Code (a s)) ~ PIsDataReprRepr a
    , MkDataReprHandler s a ( 'FZ @(Length (Code (a s)))) (Code (a s)) (Code (a s))
    ) =>
    (a s -> Term s out) ->
    DataReprHandlers out (PIsDataReprRepr a) s
  pmatchDataReprHandlers =
    mkDataReprHandler
      @_
      @s
      @a
      @( 'FZ @(Length (Code (a s))))
      @(Code (a s))
      @(Code (a s))

  pmatchRepr :: forall s b. Term s (PDataSum (PIsDataReprRepr a)) -> (a s -> Term s b) -> Term s b
  pmatchRepr dat = pmatchDataRepr dat . pmatchDataReprHandlers @a @s @b

class (Tail idx pss ~ rest) => MkDataReprHandler (s :: S) (a :: PType) (idx :: Fin n) (rest :: [[Type]]) (pss :: [[Type]]) where
  mkDataReprHandler :: forall out. (a s -> Term s out) -> DataReprHandlers out (Tail idx (GetPDataRecordArgs pss)) s

instance (Tail idx (ToPLabeled2 pss) ~ '[], Tail idx pss ~ '[]) => MkDataReprHandler s a idx '[] pss where
  mkDataReprHandler _ = DRHNil

instance
  ( r ~ TypeAt idx pss
  , r ~ '[Term s (PDataRecord fs)]
  , Generic (a s)
  , Code (a s) ~ pss
  , ToPLabeled r ~ fs
  , ToPLabeled2 rs ~ (Tail ( 'FS idx) (GetPDataRecordArgs pss))
  , Tail idx pss ~ (r ': rs)
  , Tail idx (ToPLabeled2 pss) ~ ToPLabeled2 (r ': rs)
  , MkSum idx pss
  , MkDataReprHandler s a ( 'FS idx) rs pss
  ) =>
  MkDataReprHandler s a idx (r ': rs) pss
  where
  mkDataReprHandler f =
    DRHCons (f . to . mkSOP . mkProduct) $
      mkDataReprHandler @_ @s @a @( 'FS idx) @rs @pss f
    where
      mkProduct :: Term s (PDataRecord fs) -> NP I r
      mkProduct x = I x :* Nil
      mkSOP :: NP I r -> SOP I (Code (a s))
      mkSOP = SOP . mkSum @_ @idx @pss

instance PIsDataRepr a => PIsData (PIsDataReprInstances a) where
  pdata = punsafeCoerce
  pfromData = punsafeCoerce

instance PIsDataRepr a => PMatch (PIsDataReprInstances a) where
  pmatch x f = pmatchRepr (punsafeCoerce x) (f . PIsDataReprInstances)

newtype DerivePConstantViaData (h :: Type) (p :: PType) = DerivePConstantViaData h

instance (PIsDataRepr p, PLift p, Ledger.FromData h, Ledger.ToData h) => PConstant (DerivePConstantViaData h p) where
  type PConstantRepr (DerivePConstantViaData h p) = Ledger.Data
  type PConstanted (DerivePConstantViaData h p) = p
  pconstantToRepr (DerivePConstantViaData x) = Ledger.toData x
  pconstantFromRepr x = DerivePConstantViaData <$> Ledger.fromData x
