/**
 * Pure settlement decisions for the per-user quota object.
 *
 * `QuotaDurableObject` owns storage, transactions and alarms; these functions
 * only decide what a stored receipt or reservation becomes. Keeping them pure
 * lets every phase, owner, revision and expiry case be table-tested without a
 * Durable Object, and keeps the fail-closed rules in one readable place.
 */

import type { SettlementPhase, SettlementReceipt, SettlementRequest } from './settlement.js';

/** The fields of a stored reservation the expiry policy reads. */
export interface ExpiringReservation {
  readonly expiresAt: number;
  readonly operationKey?: string;
}

/**
 * What an allowance hold becomes when reservations are swept.
 *
 * - `live`: not yet expired, so it keeps holding allowance.
 * - `charge`: a legacy live lease that expired unfinalised; its reserved upper
 *   bound is committed (a smaller measurement would already have arrived).
 * - `revoke`: an operation permit that was never consumed; the hold is dropped
 *   and the receipt records durable proof that nothing was dispatched.
 * - `retain`: an operation that may have been dispatched, or whose receipt is
 *   missing; the hold stays fail-closed, and a started receipt becomes unknown.
 */
export type ExpiryDecision =
  | { readonly kind: 'live' }
  | { readonly kind: 'charge' }
  | { readonly kind: 'revoke'; readonly receipt: SettlementReceipt }
  | { readonly kind: 'retain'; readonly receipt?: SettlementReceipt };

/** True when [expiryDecision] needs the operation's receipt. */
export function isExpiredOperation(reservation: ExpiringReservation, nowSeconds: number): boolean {
  return reservation.operationKey !== undefined && reservation.expiresAt <= nowSeconds;
}

export function expiryDecision(
  reservation: ExpiringReservation,
  nowSeconds: number,
  receipt: SettlementReceipt | undefined,
): ExpiryDecision {
  if (reservation.expiresAt > nowSeconds) return { kind: 'live' };
  if (reservation.operationKey === undefined) return { kind: 'charge' };
  if (receipt?.phase === 'reserved') return { kind: 'revoke', receipt: advance(receipt, 'not_started', nowSeconds) };
  if (receipt?.phase === 'provider_started') {
    return { kind: 'retain', receipt: advance(receipt, 'outcome_unknown', nowSeconds) };
  }
  // A missing receipt is not proof of unused quota: keep the hold fail-closed.
  return { kind: 'retain' };
}

/** The owned steps of an operation after it was reserved. */
export type OperationStep = Extract<SettlementRequest,
  { kind: 'operation_start' | 'operation_cancel' | 'operation_unknown' | 'operation_measure' }>;

/**
 * What a step does to the stored receipt.
 *
 * `refuse` answers with the current receipt and reason `conflict`; `ok` is true
 * only for a repeated, identical measurement (a lost acknowledgement). `advance`
 * stores the next receipt; `effect` names the allowance change that must be
 * written with it: dropping the hold, or committing the measured units to the
 * receipt's billing period and dropping the hold.
 */
export type StepDecision =
  | { readonly kind: 'refuse'; readonly ok: boolean }
  | { readonly kind: 'advance'; readonly receipt: SettlementReceipt; readonly effect: StepEffect };

export type StepEffect = 'none' | 'release_hold' | 'commit_measured';

/** Seconds before the first ledger reconciliation of a measured operation. */
export const FIRST_RECONCILE_DELAY_SECONDS = 30;

export function operationStep(receipt: SettlementReceipt | null, request: OperationStep): StepDecision {
  if (receipt === null || receipt.ownerId !== request.ownerId) return refuse();
  if (request.kind === 'operation_measure' && (receipt.phase === 'ledger_pending' || receipt.phase === 'settled')) {
    return refuse(receipt.actualUnits === request.actualUnits && receipt.measuredAt === request.measuredAt);
  }
  if (receipt.revision !== request.revision) return refuse();
  const now = request.nowSeconds;
  switch (request.kind) {
    case 'operation_start':
      return receipt.phase === 'reserved'
        ? { kind: 'advance', receipt: advance(receipt, 'provider_started', now), effect: 'none' } : refuse();
    case 'operation_unknown':
      return receipt.phase === 'provider_started' || receipt.phase === 'outcome_unknown'
        ? { kind: 'advance', receipt: advance(receipt, 'outcome_unknown', now), effect: 'none' } : refuse();
    case 'operation_cancel':
      return receipt.phase === 'reserved'
        ? { kind: 'advance', receipt: advance(receipt, 'not_started', now), effect: 'release_hold' } : refuse();
    case 'operation_measure': {
      if (receipt.phase !== 'provider_started' && receipt.phase !== 'outcome_unknown') return refuse();
      if (!validMeasurement(receipt, request.actualUnits, request.measuredAt)) return refuse();
      const next = advance(receipt, 'ledger_pending', now);
      next.actualUnits = request.actualUnits;
      next.measuredAt = request.measuredAt;
      next.nextReconcileAt = now + FIRST_RECONCILE_DELAY_SECONDS;
      return { kind: 'advance', receipt: next, effect: 'commit_measured' };
    }
  }
}

/** The ledger's answer when a measured operation is written to D1. */
export type ReconcileResult = 'matched' | 'conflict' | 'unavailable';

/** Upper bound on the reconciliation backoff, in seconds. */
export const MAX_RECONCILE_DELAY_SECONDS = 900;

/**
 * The receipt after one reconciliation attempt. A match settles it; a conflict
 * is kept for an operator and never retried; an unavailable ledger retries with
 * exponential backoff.
 */
export function reconcileStep(current: SettlementReceipt, result: ReconcileResult, nowSeconds: number):
SettlementReceipt {
  const next: SettlementReceipt = { ...current, revision: current.revision + 1, updatedAt: nowSeconds,
    reconcileAttempts: current.reconcileAttempts + 1 };
  if (result === 'matched') {
    next.phase = 'settled'; delete next.lastFailure; delete next.nextReconcileAt;
  } else if (result === 'conflict') {
    next.lastFailure = 'ledger_conflict'; delete next.nextReconcileAt;
  } else {
    next.lastFailure = 'ledger_unavailable';
    next.nextReconcileAt = nowSeconds + Math.min(MAX_RECONCILE_DELAY_SECONDS,
      FIRST_RECONCILE_DELAY_SECONDS * 2 ** Math.min(5, next.reconcileAttempts - 1));
  }
  return next;
}

function advance(receipt: SettlementReceipt, phase: SettlementPhase, nowSeconds: number): SettlementReceipt {
  return { ...receipt, phase, revision: receipt.revision + 1, updatedAt: nowSeconds };
}

function validMeasurement(receipt: SettlementReceipt, actualUnits: number, measuredAt: number): boolean {
  return Number.isSafeInteger(actualUnits) && actualUnits >= 0
    && Number.isSafeInteger(measuredAt) && measuredAt >= receipt.createdAt
    && !(receipt.unitKind === 'audio_seconds' && actualUnits > receipt.reservedUnits);
}

function refuse(ok = false): StepDecision {
  return { kind: 'refuse', ok };
}
