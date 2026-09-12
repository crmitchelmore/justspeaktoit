import { env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { Repository } from '../src/data/repository.js';
import { grantsAccess, type EntitlementSource, type EntitlementStatus } from '../src/entitlement.js';
import { transitionEntitlement } from '../src/routes/billing.js';

const NOW = 1800000000;
async function fixture() {
  const repository = new Repository(env.DB);
  const user = await repository.upsertUserByAppleSub(crypto.randomUUID(), null, NOW);
  const context = { repository, correlationId: 'subscription-test', nowSeconds: NOW };
  const update = (source: EntitlementSource, status: EntitlementStatus, event: number,
    end = NOW + 1000) => transitionEntitlement(context, { userId: user.id, source,
      sourceReference: `${source}-${user.id}`, status, planId: 'paid', sourceEventAt: event,
      currentPeriodStart: NOW - 1000, currentPeriodEnd: end, cancelAtPeriodEnd: false,
      revocationReason: status === 'revoked' ? 'refund' : null, reason: 'provider update',
      eventSource: source, sourceEventId: `${source}-${event}` });
  return { repository, userId: user.id, update };
}

describe('independent subscription entitlement', () => {
  for (const source of ['stripe', 'storekit'] as const) {
    for (const status of ['expired', 'revoked', 'active'] as const) {
      it(`${source} ${status} cannot remove the other provider's access`, async () => {
        const { repository, userId, update } = await fixture();
        const other = source === 'stripe' ? 'storekit' : 'stripe';
        await update(source, 'active', NOW);
        await update(other, 'active', NOW - 100, NOW + 2000);
        const outcome = await update(source, status, NOW + 10, status === 'active' ? NOW + 1500 : NOW - 1);
        expect(grantsAccess(outcome.entitlement, NOW)).toBe(true);
        expect(grantsAccess(await repository.findEntitlement(userId, NOW), NOW)).toBe(true);
        const rows = await env.DB.prepare(`SELECT status FROM subscription_states
          WHERE user_id = ?1 AND source IN ('stripe', 'storekit')`).bind(userId).all();
        expect(rows.results).toHaveLength(2);
      });
    }
  }
  it('derives access after time passes without needing another webhook', async () => {
    const { repository, userId, update } = await fixture();
    await update('stripe', 'active', NOW, NOW + 10);
    await update('storekit', 'active', NOW - 100, NOW + 100);
    expect(grantsAccess(await repository.findEntitlement(userId, NOW + 20), NOW + 20)).toBe(true);
    expect(grantsAccess(await repository.findEntitlement(userId, NOW + 101), NOW + 101)).toBe(false);
  });
  it('persists concurrent providers independently and ignores stale events only within their purchase', async () => {
    const { update } = await fixture();
    await Promise.all([update('stripe', 'active', NOW), update('storekit', 'active', NOW - 100)]);
    const stale = await update('storekit', 'expired', NOW - 200, NOW - 1);
    expect(stale.applied).toBe(false);
    expect(grantsAccess(stale.entitlement, NOW)).toBe(true);
    const expired = await update('stripe', 'expired', NOW + 10, NOW - 1);
    expect(expired.entitlement.source).toBe('storekit');
  });
});
