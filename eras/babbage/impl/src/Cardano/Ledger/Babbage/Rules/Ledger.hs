{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

module Cardano.Ledger.Babbage.Rules.Ledger
  ( BabbageLEDGER,
    ledgerTransition,
  )
where

import Cardano.Ledger.Babbage.Rules.Utxow (BabbageEvent, BabbagePredFail, BabbageUTXOW)
import Cardano.Ledger.Babbage.Tx (IsValid (..), ValidatedTx (..))
import Cardano.Ledger.BaseTypes (ShelleyBase)
import Cardano.Ledger.Coin (Coin)
import qualified Cardano.Ledger.Core as Core
import Cardano.Ledger.Era (Crypto, Era)
import Cardano.Ledger.Keys (DSignable, Hash)
import Cardano.Ledger.Shelley.EpochBoundary (obligation)
import Cardano.Ledger.Shelley.LedgerState
  ( DPState (..),
    DState (..),
    PState (..),
    UTxOState (..),
  )
import Cardano.Ledger.Shelley.Rules.Delegs (DELEGS, DelegsEnv (..), DelegsEvent, DelegsPredicateFailure)
import Cardano.Ledger.Shelley.Rules.Ledger (LedgerEnv (..), LedgerEvent (..), LedgerPredicateFailure (..))
import qualified Cardano.Ledger.Shelley.Rules.Ledgers as Shelley
import Cardano.Ledger.Shelley.Rules.Utxo
  ( UtxoEnv (..),
  )
import Cardano.Ledger.Shelley.TxBody (DCert, EraIndependentTxBody)
import Control.State.Transition
  ( Assertion (..),
    AssertionViolation (..),
    Embed (..),
    STS (..),
    TRC (..),
    TransitionRule,
    judgmentContext,
    trans,
  )
import Data.Kind (Type)
import Data.Sequence (Seq)
import Data.Sequence.Strict (StrictSeq)
import qualified Data.Sequence.Strict as StrictSeq
import GHC.Records (HasField, getField)

-- =======================================

-- | The uninhabited type that marks the (STS Ledger) instance in the Babbage Era.
data BabbageLEDGER era

-- | An abstract Babbage Era, Ledger transition. Fix 'someLedger' at a concrete type to
--   make it concrete. Depends only on the "certs" and "isValid" HasField instances.
ledgerTransition ::
  forall (someLEDGER :: Type -> Type) era.
  ( Signal (someLEDGER era) ~ Core.Tx era,
    State (someLEDGER era) ~ (UTxOState era, DPState (Crypto era)),
    Environment (someLEDGER era) ~ LedgerEnv era,
    Embed (Core.EraRule "UTXOW" era) (someLEDGER era),
    Embed (Core.EraRule "DELEGS" era) (someLEDGER era),
    Environment (Core.EraRule "DELEGS" era) ~ DelegsEnv era,
    State (Core.EraRule "DELEGS" era) ~ DPState (Crypto era),
    Signal (Core.EraRule "DELEGS" era) ~ Seq (DCert (Crypto era)),
    Environment (Core.EraRule "UTXOW" era) ~ UtxoEnv era,
    State (Core.EraRule "UTXOW" era) ~ UTxOState era,
    Signal (Core.EraRule "UTXOW" era) ~ Core.Tx era,
    HasField "certs" (Core.TxBody era) (StrictSeq (DCert (Crypto era))),
    HasField "isValid" (Core.Tx era) IsValid,
    Era era
  ) =>
  TransitionRule (someLEDGER era)
ledgerTransition = do
  TRC (LedgerEnv slot txIx pp account, (utxoSt, dpstate), tx) <- judgmentContext
  let txbody = getField @"body" tx

  dpstate' <-
    if getField @"isValid" tx == IsValid True
      then
        trans @(Core.EraRule "DELEGS" era) $
          TRC
            ( DelegsEnv slot txIx pp tx account,
              dpstate,
              StrictSeq.fromStrict $ getField @"certs" $ txbody
            )
      else pure dpstate

  let DPState dstate pstate = dpstate
      genDelegs = _genDelegs dstate
      stpools = _pParams pstate

  utxoSt' <-
    trans @(Core.EraRule "UTXOW" era) $
      TRC
        ( UtxoEnv @era slot pp stpools genDelegs,
          utxoSt,
          tx
        )
  pure (utxoSt', dpstate')

instance
  ( Show (Core.Script era), -- All these Show instances arise because
    Show (Core.TxBody era), -- renderAssertionViolation, turns them into strings
    Show (Core.AuxiliaryData era),
    Show (Core.PParams era),
    Show (Core.Value era),
    Show (Core.PParamsDelta era),
    DSignable (Crypto era) (Hash (Crypto era) EraIndependentTxBody),
    Era era,
    Core.Tx era ~ ValidatedTx era,
    Embed (Core.EraRule "DELEGS" era) (BabbageLEDGER era),
    Embed (Core.EraRule "UTXOW" era) (BabbageLEDGER era),
    Environment (Core.EraRule "UTXOW" era) ~ UtxoEnv era,
    State (Core.EraRule "UTXOW" era) ~ UTxOState era,
    Signal (Core.EraRule "UTXOW" era) ~ ValidatedTx era,
    Environment (Core.EraRule "DELEGS" era) ~ DelegsEnv era,
    State (Core.EraRule "DELEGS" era) ~ DPState (Crypto era),
    Signal (Core.EraRule "DELEGS" era) ~ Seq (DCert (Crypto era)),
    HasField "certs" (Core.TxBody era) (StrictSeq (DCert (Crypto era))),
    HasField "_keyDeposit" (Core.PParams era) Coin,
    HasField "_poolDeposit" (Core.PParams era) Coin,
    Show (UTxOState era)
  ) =>
  STS (BabbageLEDGER era)
  where
  type
    State (BabbageLEDGER era) =
      (UTxOState era, DPState (Crypto era))
  type Signal (BabbageLEDGER era) = ValidatedTx era
  type Environment (BabbageLEDGER era) = LedgerEnv era
  type BaseM (BabbageLEDGER era) = ShelleyBase
  type PredicateFailure (BabbageLEDGER era) = LedgerPredicateFailure era
  type Event (BabbageLEDGER era) = LedgerEvent era

  initialRules = []
  transitionRules = [ledgerTransition @BabbageLEDGER]

  renderAssertionViolation AssertionViolation {avSTS, avMsg, avCtx, avState} =
    "AssertionViolation (" <> avSTS <> "): " <> avMsg
      <> "\n"
      <> show avCtx
      <> "\n"
      <> show avState

  assertions =
    [ PostCondition
        "Deposit pot must equal obligation"
        ( \(TRC (LedgerEnv {ledgerPp}, _, _))
           (utxoSt, DPState {_dstate, _pstate}) ->
              obligation ledgerPp (_rewards _dstate) (_pParams _pstate)
                == _deposited utxoSt
        )
    ]

instance
  ( Era era,
    STS (DELEGS era),
    PredicateFailure (Core.EraRule "DELEGS" era) ~ DelegsPredicateFailure era,
    Event (Core.EraRule "DELEGS" era) ~ DelegsEvent era
  ) =>
  Embed (DELEGS era) (BabbageLEDGER era)
  where
  wrapFailed = DelegsFailure
  wrapEvent = DelegsEvent

instance
  ( Era era,
    STS (BabbageUTXOW era),
    PredicateFailure (Core.EraRule "UTXOW" era) ~ BabbagePredFail era,
    Event (Core.EraRule "UTXOW" era) ~ BabbageEvent era
  ) =>
  Embed (BabbageUTXOW era) (BabbageLEDGER era)
  where
  wrapFailed = UtxowFailure
  wrapEvent = UtxowEvent

instance
  ( Era era,
    STS (BabbageLEDGER era),
    PredicateFailure (Core.EraRule "LEDGER" era) ~ LedgerPredicateFailure era,
    Event (Core.EraRule "LEDGER" era) ~ LedgerEvent era
  ) =>
  Embed (BabbageLEDGER era) (Shelley.LEDGERS era)
  where
  wrapFailed = Shelley.LedgerFailure
  wrapEvent = Shelley.LedgerEvent