{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-orphans -Wno-redundant-constraints #-}

module Plutarch.DataRepr (
  PDataRepr,
  punDataRepr,
  pindexDataRepr,
  pmatchDataRepr,
  DataReprHandlers (..),
  PDataList,
  pdhead,
  pdtail,
  PIsDataRepr (..),
  PIsDataReprInstances (..),
  punsafeIndex,
  pindexDataList,
  DerivePConstantViaData (..),
) where

import Data.List (groupBy, maximumBy, sortOn)
import Data.Proxy (Proxy)
import GHC.TypeLits (KnownNat, Nat, natVal, type (-))
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
import Plutarch.Integer (PInteger)
import Plutarch.Lift (
  PConstant,
  PConstantRepr,
  PConstanted,
  PLift,
  pconstant,
  pconstantFromRepr,
  pconstantToRepr,
 )
import Plutarch.List (punsafeIndex)
import Plutarch.Prelude
import qualified Plutus.V1.Ledger.Api as Ledger
import qualified PlutusCore as PLC

data PDataList (as :: [PType]) (s :: S)

pdhead :: Term s (PDataList (a : as) :--> PAsData a)
pdhead = phoistAcyclic $ pforce $ punsafeBuiltin PLC.HeadList

pdtail :: Term s (PDataList (a : as) :--> PDataList as)
pdtail = phoistAcyclic $ pforce $ punsafeBuiltin PLC.TailList

type PDataRepr :: [[PType]] -> PType
data PDataRepr (defs :: [[PType]]) (s :: S)

pasData :: Term s (PDataRepr _) -> Term s PData
pasData = punsafeCoerce

type family IndexList (n :: Nat) (l :: [k]) :: k where
  IndexList 0 (x ': _) = x
  IndexList n (x : xs) = IndexList (n - 1) xs

punDataRepr :: Term s (PDataRepr '[def] :--> PDataList def)
punDataRepr = phoistAcyclic $
  plam $ \t ->
    plet (pasConstr #$ pasData t) $ \d ->
      (punsafeCoerce $ psndBuiltin # d :: Term _ (PDataList def))

pindexDataRepr ::
  (KnownNat n) =>
  Proxy n ->
  Term s (PDataRepr (def : defs) :--> PDataList (IndexList n (def : defs)))
pindexDataRepr n = phoistAcyclic $
  plam $ \t ->
    plet (pasConstr #$ pasData t) $ \d ->
      let i :: Term _ PInteger = pfstBuiltin # d
       in pif
            (i #== pconstant (natVal n))
            (punsafeCoerce $ psndBuiltin # d :: Term _ (PDataList _))
            perror

-- | Safely index a DataList
pindexDataList :: (KnownNat n) => Proxy n -> Term s (PDataList xs :--> PAsData (IndexList n xs))
pindexDataList n =
  phoistAcyclic $
    punsafeCoerce $
      punsafeIndex @PBuiltinList @PData # ind
  where
    ind :: Term s PInteger
    ind = pconstant $ natVal n

data DataReprHandlers (out :: PType) (def :: [[PType]]) (s :: S) where
  DRHNil :: DataReprHandlers out '[] s
  DRHCons :: (Term s (PDataList def) -> Term s out) -> DataReprHandlers out defs s -> DataReprHandlers out (def : defs) s

pmatchDataRepr :: Term s (PDataRepr (def : defs)) -> DataReprHandlers out (def : defs) s -> Term s out
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
              (pconstant idx #== constr)
              handler
              $ go common (idx + 1) rest constr

newtype PIsDataReprInstances (a :: PType) (s :: S) = PIsDataReprInstances (a s)

class (PMatch a, PIsData a) => PIsDataRepr (a :: PType) where
  type PIsDataReprRepr a :: [[PType]]
  pmatchRepr :: forall s b. Term s (PDataRepr (PIsDataReprRepr a)) -> (a s -> Term s b) -> Term s b

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
