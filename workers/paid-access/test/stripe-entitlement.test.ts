import { describe, expect, it } from 'vitest';
import {
  decideStripeEvent,
  subscriptionView,
  type StripeAttributionLookups,
} from '../src/billing/stripe-entitlement.js';
import { StripeError, type StripeEvent } from '../src/billing/stripe.js';

const MONTHLY = 'price_monthly';
const YEARLY = 'price_yearly';
const PLAN = [MONTHLY, YEARLY];

function event(
  object: Record<string, unknown> = {},
  type = 'customer.subscription.updated',
): StripeEvent {
  return {
    id: 'evt_1',
    type,
    created: 1_800_000_000,
    data: {
      object: {
        id: 'sub_1',
        customer: 'cus_1',
        status: 'active',
        current_period_start: 1_799_000_000,
        current_period_end: 1_801_000_000,
        cancel_at_period_end: false,
        metadata: {},
        items: { data: [{ price: { id: MONTHLY } }] },
        ...object,
      },
    },
  };
}

function lookups(
  customerUser: string | null,
  subscriptionOwner: string | null = customerUser,
): StripeAttributionLookups & { calls: string[] } {
  const calls: string[] = [];
  return {
    calls,
    findUserByCustomer: (customerId) => {
      calls.push(`customer:${customerId}`);
      return Promise.resolve(customerUser);
    },
    findSubscriptionOwner: (subscriptionId) => {
      calls.push(`subscription:${subscriptionId}`);
      return Promise.resolve(subscriptionOwner);
    },
  };
}

describe('decideStripeEvent', () => {
  it('ignores non-subscription events without any lookup', async () => {
    const seen = lookups('user-1');
    const decision = await decideStripeEvent(event({}, 'invoice.paid'), PLAN, seen);
    expect(decision).toEqual({ kind: 'ignore', reason: null });
    expect(seen.calls).toEqual([]);
  });

  it('refuses a granting event on a price this plan does not sell, before attributing it', async () => {
    const seen = lookups('user-1');
    const decision = await decideStripeEvent(
      event({ items: { data: [{ price: { id: 'price_other_product' } }] } }),
      PLAN,
      seen,
    );
    expect(decision).toEqual({ kind: 'ignore', reason: 'price_not_in_plan' });
    expect(seen.calls).toEqual([]);
  });

  it('applies a cancellation without line items, scoped to the current subscription', async () => {
    const seen = lookups('user-1', 'user-1');
    const decision = await decideStripeEvent(
      event({ items: { data: [] } }, 'customer.subscription.deleted'),
      PLAN,
      seen,
    );
    expect(decision.kind).toBe('apply');
    expect(decision.kind === 'apply' && decision.transition.status).toBe('expired');
    expect(seen.calls).toEqual(['customer:cus_1', 'subscription:sub_1']);
  });

  it('ignores a cancellation for a subscription the entitlement does not name', async () => {
    const decision = await decideStripeEvent(
      event({ status: 'canceled' }),
      PLAN,
      lookups('user-1', 'user-2'),
    );
    expect(decision).toEqual({ kind: 'ignore', reason: 'subscription_not_current' });
  });

  it('fails when metadata disagrees with the stored customer mapping', async () => {
    const decision = await decideStripeEvent(
      event({ metadata: { user_id: 'someone-else' } }),
      PLAN,
      lookups('user-1'),
    );
    expect(decision).toEqual({ kind: 'fail', reason: 'metadata_user_mismatch' });
  });

  it('fails an unmapped customer even when metadata names a user', async () => {
    const decision = await decideStripeEvent(
      event({ metadata: { user_id: 'user-1' } }),
      PLAN,
      lookups(null),
    );
    expect(decision).toEqual({ kind: 'fail', reason: 'unattributable_customer' });
  });

  it('records the price actually billed and every transition field', async () => {
    const decision = await decideStripeEvent(
      event({
        cancel_at_period_end: true,
        items: { data: [{ price: 'price_addon' }, { price: { id: YEARLY } }] },
      }),
      PLAN,
      lookups('user-1'),
    );
    expect(decision).toEqual({
      kind: 'apply',
      transition: {
        userId: 'user-1',
        status: 'active',
        planId: YEARLY,
        source: 'stripe',
        sourceReference: 'sub_1',
        currentPeriodStart: 1_799_000_000,
        currentPeriodEnd: 1_801_000_000,
        cancelAtPeriodEnd: true,
        revocationReason: null,
        sourceEventAt: 1_800_000_000,
        reason: 'customer.subscription.updated',
        eventSource: 'stripe',
        sourceEventId: 'evt_1',
      },
    });
  });

  it('rejects an unknown subscription status as a parse failure', async () => {
    await expect(
      decideStripeEvent(event({ status: 'mystery' }), PLAN, lookups('user-1')),
    ).rejects.toBeInstanceOf(StripeError);
  });
});

describe('subscriptionView', () => {
  it('reads period boundaries from the first item on newer API versions', () => {
    const view = subscriptionView(
      event({
        current_period_start: undefined,
        current_period_end: undefined,
        items: { data: [{ price: MONTHLY, current_period_start: 10, current_period_end: 20 }] },
      }),
    );
    expect(view).toMatchObject({ currentPeriodStart: 10, currentPeriodEnd: 20, priceIds: [MONTHLY] });
  });

  it('drops a non-string metadata user id', () => {
    expect(subscriptionView(event({ metadata: { user_id: 42 } }))?.userIdHint).toBeNull();
  });
});
