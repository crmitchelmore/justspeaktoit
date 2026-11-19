import { describe, expect, it } from 'vitest';
import {
  expiryDecision, FIRST_RECONCILE_DELAY_SECONDS, isExpiredOperation, MAX_RECONCILE_DELAY_SECONDS,
  operationStep, reconcileStep, type OperationStep, type ReconcileResult,
} from '../src/do/quota-policy.js';
import type { SettlementPhase, SettlementReceipt } from '../src/do/settlement.js';

const NOW = 1_800_000_000;
const OWNER = 'owner-a';

function receipt(phase: SettlementPhase, extra: Partial<SettlementReceipt> = {}): SettlementReceipt {
  return {
    schemaVersion: 1, userId: 'user', idempotencyKey: 'policy-operation-0001', operation: 'post_processing',
    reservationId: 'reservation', ledgerEntryId: 'ledger', ownerId: OWNER, provider: 'openrouter',
    model: 'openai/gpt-5-mini', unitKind: 'tokens', billingPeriod: '2027-01', reservedUnits: 100, phase,
    revision: 3, createdAt: NOW - 10, updatedAt: NOW - 10, expiresAt: NOW + 50, correlationId: 'corr',
    reconcileAttempts: 0, ...extra,
  };
}

function step(kind: OperationStep['kind'], extra: Partial<OperationStep> = {}): OperationStep {
  const base = { idempotencyKey: 'policy-operation-0001', ownerId: OWNER, revision: 3, nowSeconds: NOW };
  return (kind === 'operation_measure'
    ? { kind, ...base, actualUnits: 60, measuredAt: NOW, ...extra }
    : { kind, ...base, ...extra }) as OperationStep;
}

describe('expiryDecision', () => {
  const keyed = { expiresAt: NOW, operationKey: 'policy-operation-0001' };
  it.each([
    ['an unexpired legacy lease', { expiresAt: NOW + 1 }, undefined, 'live', undefined],
    ['an expired legacy lease', { expiresAt: NOW }, undefined, 'charge', undefined],
    ['an unexpired operation', { ...keyed, expiresAt: NOW + 1 }, receipt('reserved'), 'live', undefined],
    ['an expired unconsumed permit', keyed, receipt('reserved'), 'revoke', 'not_started'],
    ['an expired dispatched operation', keyed, receipt('provider_started'), 'retain', 'outcome_unknown'],
    ['an expired unknown operation', keyed, receipt('outcome_unknown'), 'retain', undefined],
    ['an expired operation with no receipt', keyed, undefined, 'retain', undefined],
  ] as const)('%s → %s', (_name, reservation, stored, kind, phase) => {
    const decision = expiryDecision(reservation, NOW, stored);
    expect(decision.kind).toBe(kind);
    const next = 'receipt' in decision ? decision.receipt : undefined;
    expect(next?.phase).toBe(phase);
    if (next !== undefined) expect(next).toMatchObject({ revision: 4, updatedAt: NOW });
  });

  it('needs a receipt only for an expired operation', () => {
    expect(isExpiredOperation(keyed, NOW)).toBe(true);
    expect(isExpiredOperation({ ...keyed, expiresAt: NOW + 1 }, NOW)).toBe(false);
    expect(isExpiredOperation({ expiresAt: NOW }, NOW)).toBe(false);
  });
});

describe('operationStep', () => {
  it.each([
    ['start', 'reserved', 'provider_started', 'none'],
    ['unknown', 'provider_started', 'outcome_unknown', 'none'],
    ['unknown', 'outcome_unknown', 'outcome_unknown', 'none'],
    ['cancel', 'reserved', 'not_started', 'release_hold'],
    ['measure', 'provider_started', 'ledger_pending', 'commit_measured'],
    ['measure', 'outcome_unknown', 'ledger_pending', 'commit_measured'],
  ] as const)('%s from %s advances to %s with effect %s', (kind, from, to, effect) => {
    const decision = operationStep(receipt(from), step(`operation_${kind}`));
    expect(decision).toMatchObject({ kind: 'advance', effect, receipt: { phase: to, revision: 4, updatedAt: NOW } });
  });

  it.each([
    ['start', 'provider_started'], ['start', 'not_started'], ['start', 'outcome_unknown'],
    ['unknown', 'reserved'], ['unknown', 'not_started'],
    ['cancel', 'provider_started'], ['cancel', 'outcome_unknown'], ['cancel', 'not_started'],
    ['measure', 'reserved'], ['measure', 'not_started'],
  ] as const)('%s from %s is refused', (kind, from) => {
    expect(operationStep(receipt(from), step(`operation_${kind}`))).toEqual({ kind: 'refuse', ok: false });
  });

  it('refuses a missing receipt, another owner and a stale revision', () => {
    expect(operationStep(null, step('operation_start'))).toEqual({ kind: 'refuse', ok: false });
    expect(operationStep(receipt('reserved'), step('operation_start', { ownerId: 'owner-b' })))
      .toEqual({ kind: 'refuse', ok: false });
    expect(operationStep(receipt('reserved'), step('operation_start', { revision: 2 })))
      .toEqual({ kind: 'refuse', ok: false });
  });

  it('records the measurement and schedules the first reconciliation', () => {
    const decision = operationStep(receipt('provider_started'), step('operation_measure'));
    expect(decision).toMatchObject({ receipt: { actualUnits: 60, measuredAt: NOW,
      nextReconcileAt: NOW + FIRST_RECONCILE_DELAY_SECONDS } });
  });

  it.each([
    ['negative units', { actualUnits: -1 }, {}],
    ['fractional units', { actualUnits: 1.5 }, {}],
    ['a measurement before creation', { measuredAt: NOW - 11 }, {}],
    ['audio above its reservation', { actualUnits: 101 }, { unitKind: 'audio_seconds' as const }],
  ])('refuses %s', (_name, measured, stored) => {
    expect(operationStep(receipt('provider_started', stored), step('operation_measure', measured)))
      .toEqual({ kind: 'refuse', ok: false });
  });

  it('allows a token overrun, which stays visible as usage', () => {
    expect(operationStep(receipt('provider_started'), step('operation_measure', { actualUnits: 101 })).kind)
      .toBe('advance');
  });

  it.each(['ledger_pending', 'settled'] as const)('answers a repeated measurement of a %s receipt', phase => {
    const measured = receipt(phase, { actualUnits: 60, measuredAt: NOW, revision: 9 });
    // A lost acknowledgement: identical measurement, any revision, is reported ok without a change.
    expect(operationStep(measured, step('operation_measure'))).toEqual({ kind: 'refuse', ok: true });
    expect(operationStep(measured, step('operation_measure', { actualUnits: 61 })))
      .toEqual({ kind: 'refuse', ok: false });
  });
});

describe('reconcileStep', () => {
  const pending = receipt('ledger_pending', { actualUnits: 60, measuredAt: NOW, nextReconcileAt: NOW,
    lastFailure: 'ledger_unavailable', reconcileAttempts: 1 });

  it.each([
    ['matched', { phase: 'settled', lastFailure: undefined, nextReconcileAt: undefined }],
    ['conflict', { phase: 'ledger_pending', lastFailure: 'ledger_conflict', nextReconcileAt: undefined }],
    ['unavailable', { phase: 'ledger_pending', lastFailure: 'ledger_unavailable', nextReconcileAt: NOW + 60 }],
  ] as const)('%s', (result: ReconcileResult, expected) => {
    const next = reconcileStep(pending, result, NOW);
    expect(next).toMatchObject({ revision: 4, updatedAt: NOW, reconcileAttempts: 2 });
    expect({ phase: next.phase, lastFailure: next.lastFailure, nextReconcileAt: next.nextReconcileAt })
      .toEqual(expected);
  });

  it('backs off exponentially up to its cap', () => {
    const delays = [0, 1, 2, 3, 4, 5, 9].map(attempts =>
      reconcileStep({ ...pending, reconcileAttempts: attempts }, 'unavailable', NOW).nextReconcileAt! - NOW);
    expect(delays).toEqual([30, 60, 120, 240, 480, 900, MAX_RECONCILE_DELAY_SECONDS]);
  });
});
