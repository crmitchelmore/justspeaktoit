import { describe, expect, it } from 'vitest';
import {
  applyUpdate,
  billingPeriod,
  canTransition,
  effectiveStatus,
  EntitlementTransitionError,
  grantsAccess,
  type Entitlement,
} from '../src/entitlement.js';

const NOW = 1_800_000_000;

function makeEntitlement(overrides: Partial<Entitlement> = {}): Entitlement {
  return {
    id: 'ent-1',
    userId: 'user-1',
    planId: 'free',
    status: 'none',
    source: 'manual',
    sourceReference: null,
    currentPeriodStart: null,
    currentPeriodEnd: null,
    cancelAtPeriodEnd: false,
    revokedAt: null,
    revocationReason: null,
    version: 1,
    sourceEventAt: null,
    ...overrides,
  };
}

describe('entitlement access', () => {
  it('grants access while an active period is open', () => {
    const entitlement = makeEntitlement({ status: 'active', currentPeriodEnd: NOW + 60 });
    expect(grantsAccess(entitlement, NOW)).toBe(true);
  });

  it('denies access once the period has ended even if the stored status still says active', () => {
    const entitlement = makeEntitlement({ status: 'active', currentPeriodEnd: NOW - 1 });
    expect(grantsAccess(entitlement, NOW)).toBe(false);
    expect(effectiveStatus(entitlement, NOW)).toBe('expired');
  });

  it('grants access during a grace period and denies it once grace ends', () => {
    const inGrace = makeEntitlement({ status: 'grace', currentPeriodEnd: NOW + 10 });
    const afterGrace = makeEntitlement({ status: 'grace', currentPeriodEnd: NOW - 10 });
    expect(grantsAccess(inGrace, NOW)).toBe(true);
    expect(grantsAccess(afterGrace, NOW)).toBe(false);
  });

  it('denies access when revoked regardless of the period', () => {
    const entitlement = makeEntitlement({
      status: 'revoked',
      currentPeriodEnd: NOW + 10_000,
      revokedAt: NOW - 5,
    });
    expect(grantsAccess(entitlement, NOW)).toBe(false);
    expect(effectiveStatus(entitlement, NOW)).toBe('revoked');
  });

  it('denies access when there is no entitlement at all', () => {
    expect(grantsAccess(null, NOW)).toBe(false);
    expect(effectiveStatus(null, NOW)).toBe('none');
  });

  it('denies access to past_due accounts', () => {
    const entitlement = makeEntitlement({ status: 'past_due', currentPeriodEnd: NOW + 1_000 });
    expect(grantsAccess(entitlement, NOW)).toBe(false);
  });
});

describe('entitlement transitions', () => {
  it('allows the ordinary purchase and renewal path', () => {
    expect(canTransition('none', 'active')).toBe(true);
    expect(canTransition('active', 'active')).toBe(true);
    expect(canTransition('trialing', 'active')).toBe(true);
    expect(canTransition('active', 'past_due')).toBe(true);
    expect(canTransition('past_due', 'active')).toBe(true);
    expect(canTransition('expired', 'active')).toBe(true);
  });

  it('treats revoked as terminal but lets a redelivered revocation through', () => {
    expect(canTransition('revoked', 'active')).toBe(false);
    expect(canTransition('active', 'revoked')).toBe(true);
    // Providers redeliver. A second revocation must be a harmless no-op, not an
    // error that has the provider retry an event that can never succeed.
    expect(canTransition('revoked', 'revoked')).toBe(true);
  });

  it('refuses to revive the very subscription that was revoked', () => {
    const revoked = makeEntitlement({
      status: 'revoked',
      revokedAt: NOW - 100,
      sourceReference: 'sub_1',
    });
    expect(() =>
      applyUpdate(
        revoked,
        {
          status: 'active',
          planId: 'paid',
          source: 'stripe',
          sourceReference: 'sub_1',
          currentPeriodStart: NOW,
          currentPeriodEnd: NOW + 1_000,
          cancelAtPeriodEnd: false,
          revocationReason: null,
          sourceEventAt: NOW,
        },
        NOW,
      ),
    ).toThrow(EntitlementTransitionError);
  });

  it('re-entitles a revoked account that buys a new subscription', () => {
    // A refund revokes. If revocation were terminal for the account rather than
    // for the subscription, the user could pay again and never get access back.
    const revoked = makeEntitlement({
      status: 'revoked',
      revokedAt: NOW - 100,
      sourceReference: 'sub_refunded',
      revocationReason: 'refund',
    });
    const outcome = applyUpdate(
      revoked,
      {
        status: 'active',
        planId: 'paid',
        source: 'stripe',
        sourceReference: 'sub_bought_again',
        currentPeriodStart: NOW,
        currentPeriodEnd: NOW + 1_000,
        cancelAtPeriodEnd: false,
        revocationReason: null,
        sourceEventAt: NOW,
      },
      NOW,
    );

    expect(outcome.kind).toBe('applied');
    if (outcome.kind !== 'applied') return;
    expect(outcome.next.status).toBe('active');
    expect(grantsAccess(outcome.next, NOW)).toBe(true);
    // The old revocation must not linger: `grantsAccess` refuses anything with a
    // revocation stamp regardless of status.
    expect(outcome.next.revokedAt).toBeNull();
    expect(outcome.next.revocationReason).toBeNull();
    expect(outcome.next.sourceReference).toBe('sub_bought_again');
  });

  it('discards an update that is older than the state already stored', () => {
    const current = makeEntitlement({
      status: 'active',
      sourceEventAt: NOW,
      currentPeriodEnd: NOW + 1_000,
    });
    const outcome = applyUpdate(
      current,
      {
        status: 'past_due',
        planId: 'paid',
        source: 'stripe',
        sourceReference: 'sub_1',
        currentPeriodStart: NOW - 5_000,
        currentPeriodEnd: NOW - 1,
        cancelAtPeriodEnd: false,
        revocationReason: null,
        sourceEventAt: NOW - 10,
      },
      NOW,
    );
    expect(outcome.kind).toBe('stale');
  });

  it('increments the version on every applied update so concurrent writers conflict', () => {
    const current = makeEntitlement({ status: 'none', version: 4 });
    const outcome = applyUpdate(
      current,
      {
        status: 'active',
        planId: 'paid',
        source: 'stripe',
        sourceReference: 'sub_1',
        currentPeriodStart: NOW,
        currentPeriodEnd: NOW + 1_000,
        cancelAtPeriodEnd: false,
        revocationReason: null,
        sourceEventAt: NOW,
      },
      NOW,
    );
    expect(outcome.kind).toBe('applied');
    if (outcome.kind !== 'applied') return;
    expect(outcome.next.version).toBe(5);
    expect(outcome.next.revokedAt).toBeNull();
  });

  it('stamps a revocation timestamp when moving to revoked', () => {
    const current = makeEntitlement({ status: 'active', currentPeriodEnd: NOW + 100 });
    const outcome = applyUpdate(
      current,
      {
        status: 'revoked',
        planId: 'paid',
        source: 'storekit',
        sourceReference: 'orig_1',
        currentPeriodStart: NOW - 100,
        currentPeriodEnd: NOW + 100,
        cancelAtPeriodEnd: true,
        revocationReason: 'apple_refund',
        sourceEventAt: NOW,
      },
      NOW,
    );
    expect(outcome.kind).toBe('applied');
    if (outcome.kind !== 'applied') return;
    expect(outcome.next.revokedAt).toBe(NOW);
    expect(outcome.next.revocationReason).toBe('apple_refund');
    expect(grantsAccess(outcome.next, NOW)).toBe(false);
  });
});

describe('billing period', () => {
  it('produces a stable YYYY-MM key in UTC', () => {
    expect(billingPeriod(Date.UTC(2026, 7, 12, 9, 0, 0) / 1_000)).toBe('2026-08');
    expect(billingPeriod(Date.UTC(2026, 0, 1, 0, 0, 0) / 1_000)).toBe('2026-01');
  });
});
