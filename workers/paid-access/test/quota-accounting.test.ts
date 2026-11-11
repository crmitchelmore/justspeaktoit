import { describe, expect, it } from 'vitest';
import {
  admitLease, admitOperation, chargeExpiredLeases, emptyPeriod, settleLease, sweepReservations,
  type LeaseRequest, type QuotaLimits, type Reservation,
} from '../src/do/quota-accounting.js';
import type { SettlementReceipt, SettlementRequest } from '../src/do/settlement.js';

const NOW = 1_800_000_000;
const PERIOD = '2027-01';
const LIMITS: QuotaLimits = { monthlyAudioSeconds: 100, monthlyTokens: 1_000, maxConcurrentSessions: 1, leaseSeconds: 60 };

function lease(extra: Partial<Reservation> = {}): Reservation {
  return { id: 'lease', period: PERIOD, unitKind: 'audio_seconds', units: 30, countsAsSession: true,
    expiresAt: NOW + 60, ...extra };
}

function leaseRequest(extra: Partial<LeaseRequest> = {}): LeaseRequest {
  return { period: PERIOD, unitKind: 'audio_seconds', units: 20, limits: LIMITS, countsAsSession: false,
    nowSeconds: NOW, ...extra };
}

describe('sweepReservations', () => {
  it('keeps live holds, charges expired leases and revokes unused permits in one pass', () => {
    const live = lease({ id: 'live' });
    const expired = lease({ id: 'expired', expiresAt: NOW });
    const permit = lease({ id: 'permit', expiresAt: NOW, operationKey: 'permit-key' });
    const unknown = lease({ id: 'unknown', expiresAt: NOW, operationKey: 'missing-key' });
    const receipt = { idempotencyKey: 'permit-key', phase: 'reserved', revision: 1 } as SettlementReceipt;

    const sweep = sweepReservations([live, expired, permit, unknown], new Map([['permit-key', receipt]]), NOW);

    expect(sweep.live.map((entry) => entry.id)).toEqual(['live', 'unknown']);
    expect(sweep.expired.map((entry) => entry.id)).toEqual(['expired']);
    expect(sweep.receiptUpdates).toEqual([expect.objectContaining({ idempotencyKey: 'permit-key',
      phase: 'not_started', revision: 2 })]);
  });
});

describe('chargeExpiredLeases', () => {
  it('charges each lease in full to its own period and marks measured usage unknown', () => {
    const periods = new Map([[PERIOD, emptyPeriod(PERIOD)], ['2026-12', emptyPeriod('2026-12')]]);
    const charged = chargeExpiredLeases(periods, [
      lease({ units: 30 }), lease({ unitKind: 'tokens', units: 7 }), lease({ period: '2026-12', units: 5 }),
    ]);
    expect(charged).toEqual([
      { period: PERIOD, audioSecondsCommitted: 30, tokensCommitted: 7, measuredKnown: false },
      { period: '2026-12', audioSecondsCommitted: 5, tokensCommitted: 0, measuredKnown: false },
    ]);
    expect(periods.get(PERIOD)?.audioSecondsCommitted).toBe(0);
  });
});

describe('admitLease', () => {
  it('refuses a session beyond the concurrency limit before checking the allowance', () => {
    const admission = admitLease(leaseRequest({ countsAsSession: true, units: 1_000 }),
      emptyPeriod(PERIOD), [lease()], 'new');
    expect(admission).toMatchObject({ ok: false, reason: 'too_many_sessions' });
  });

  it('refuses a lease that would exceed the monthly allowance', () => {
    const admission = admitLease(leaseRequest({ units: 71 }), emptyPeriod(PERIOD), [lease()], 'new');
    expect(admission).toMatchObject({ ok: false, reason: 'quota_exceeded', snapshot: { audioSecondsUsed: 30 } });
  });

  it('admits a rounded-up lease that expires after the lease window', () => {
    const admission = admitLease(leaseRequest({ units: 19.2 }), emptyPeriod(PERIOD), [lease()], 'new');
    expect(admission).toMatchObject({ ok: true, reservation: { id: 'new', units: 20, expiresAt: NOW + 60 } });
    expect(admission.ok && admission.reservations.map((entry) => entry.id)).toEqual(['lease', 'new']);
  });
});

describe('settleLease', () => {
  it.each([
    ['a live audio lease commits the measurement, capped at the hold', 'audio_seconds', true, 45, 30],
    ['a live token lease keeps an overrun visible', 'tokens', true, 45, 45],
    ['an expired lease refunds the unused part of its full charge', 'audio_seconds', false, 10, -20],
  ] as const)('%s', (_name, unitKind, wasLive, actual, delta) => {
    const settled = settleLease(emptyPeriod(PERIOD), lease({ unitKind }), wasLive, actual);
    const committed = unitKind === 'tokens' ? settled.tokensCommitted : settled.audioSecondsCommitted;
    expect(committed).toBe(delta);
  });
});

describe('admitOperation', () => {
  const request = {
    kind: 'operation_reserve', userId: 'user', idempotencyKey: 'operation-key-0001', operation: 'post_processing',
    ownerId: 'owner', provider: 'openrouter', model: 'model', unitKind: 'tokens', period: PERIOD, units: 400,
    correlationId: 'corr', nowSeconds: NOW, limits: LIMITS,
  } as Extract<SettlementRequest, { kind: 'operation_reserve' }>;
  const ids = { reservationId: 'reservation', ledgerEntryId: 'ledger' };

  it('refuses a hold the allowance cannot cover', () => {
    const period = { ...emptyPeriod(PERIOD), tokensCommitted: 601 };
    expect(admitOperation(request, period, [], ids)).toEqual({ ok: false });
  });

  it('builds the reserved receipt and its keyed, non-session hold', () => {
    const admission = admitOperation(request, emptyPeriod(PERIOD), [], ids);
    expect(admission).toMatchObject({
      ok: true,
      receipt: { phase: 'reserved', revision: 1, reservationId: 'reservation', ledgerEntryId: 'ledger',
        reservedUnits: 400, billingPeriod: PERIOD, expiresAt: NOW + 60, reconcileAttempts: 0 },
      reservation: { id: 'reservation', units: 400, countsAsSession: false, operationKey: 'operation-key-0001',
        expiresAt: NOW + 60 },
    });
  });
});
