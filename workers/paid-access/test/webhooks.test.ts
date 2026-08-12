import { env, SELF } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { hmacSha256Hex } from '../src/crypto.js';

const WEBHOOK_SECRET = 'whsec_test_placeholder';

interface StripeSubscriptionEvent {
  id: string;
  type: string;
  created: number;
  data: { object: Record<string, unknown> };
}

function subscriptionEvent(overrides: Partial<StripeSubscriptionEvent> = {}): StripeSubscriptionEvent {
  const now = Math.floor(Date.now() / 1_000);
  return {
    id: `evt_${crypto.randomUUID()}`,
    type: 'customer.subscription.updated',
    created: now,
    data: {
      object: {
        id: 'sub_test_1',
        customer: 'cus_test_1',
        status: 'active',
        current_period_start: now - 100,
        current_period_end: now + 86_400,
        cancel_at_period_end: false,
        metadata: {},
      },
    },
    ...overrides,
  };
}

async function postStripeWebhook(
  event: StripeSubscriptionEvent,
  options: { timestamp?: number; signature?: string } = {},
): Promise<Response> {
  const payload = JSON.stringify(event);
  const timestamp = options.timestamp ?? Math.floor(Date.now() / 1_000);
  const signature =
    options.signature ?? (await hmacSha256Hex(WEBHOOK_SECRET, `${timestamp}.${payload}`));
  const response: Response = await SELF.fetch('https://api.test/v1/webhooks/stripe', {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      'stripe-signature': `t=${timestamp},v1=${signature}`,
    },
    body: payload,
  });
  return response;
}

async function seedStripeUser(): Promise<string> {
  const userId = crypto.randomUUID();
  const now = Math.floor(Date.now() / 1_000);
  await env.DB.prepare(
    `INSERT INTO users (id, apple_sub, role, created_at, updated_at)
     VALUES (?1, ?2, 'user', ?3, ?3)`,
  )
    .bind(userId, `apple-${userId}`, now)
    .run();
  await env.DB.prepare(
    `INSERT INTO billing_customers
       (id, user_id, provider, provider_customer_id, created_at, updated_at)
     VALUES (?1, ?2, 'stripe', 'cus_test_1', ?3, ?3)`,
  )
    .bind(crypto.randomUUID(), userId, now)
    .run();
  return userId;
}

async function entitlementStatus(userId: string): Promise<string | null> {
  const row = await env.DB.prepare('SELECT status FROM entitlements WHERE user_id = ?1')
    .bind(userId)
    .first<{ status: string }>();
  return row?.status ?? null;
}

describe('Stripe webhook signature verification', () => {
  it('rejects a delivery with no signature header', async () => {
    const response = await SELF.fetch('https://api.test/v1/webhooks/stripe', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(subscriptionEvent()),
    });
    expect(response.status).toBe(401);
  });

  it('rejects a delivery whose signature does not match the payload', async () => {
    const response = await postStripeWebhook(subscriptionEvent(), {
      signature: 'a'.repeat(64),
    });
    expect(response.status).toBe(401);
  });

  it('rejects a correctly signed but stale delivery outside the tolerance window', async () => {
    const staleTimestamp = Math.floor(Date.now() / 1_000) - 3_600;
    const response = await postStripeWebhook(subscriptionEvent(), { timestamp: staleTimestamp });
    expect(response.status).toBe(401);
  });

  it('rejects a delivery signed with a different secret', async () => {
    const event = subscriptionEvent();
    const payload = JSON.stringify(event);
    const timestamp = Math.floor(Date.now() / 1_000);
    const signature = await hmacSha256Hex('whsec_the_wrong_secret', `${timestamp}.${payload}`);
    const response = await postStripeWebhook(event, { timestamp, signature });
    expect(response.status).toBe(401);
  });

  it('records nothing in the ledger for a rejected delivery', async () => {
    await postStripeWebhook(subscriptionEvent(), { signature: 'b'.repeat(64) });
    const row = await env.DB.prepare('SELECT COUNT(*) AS total FROM webhook_events').first<{
      total: number;
    }>();
    expect(row?.total).toBe(0);
  });
});

describe('Stripe webhook idempotency', () => {
  it('activates an entitlement on first delivery', async () => {
    const userId = await seedStripeUser();
    const response = await postStripeWebhook(subscriptionEvent());
    expect(response.status).toBe(200);
    expect(await entitlementStatus(userId)).toBe('active');
  });

  it('treats a replayed delivery as a duplicate without reprocessing', async () => {
    const userId = await seedStripeUser();
    const event = subscriptionEvent();

    const first = await postStripeWebhook(event);
    expect(((await first.json()) as { duplicate?: boolean }).duplicate).toBeUndefined();

    const second = await postStripeWebhook(event);
    expect(second.status).toBe(200);
    expect(((await second.json()) as { duplicate?: boolean }).duplicate).toBe(true);

    const events = await env.DB.prepare(
      'SELECT COUNT(*) AS total FROM entitlement_events WHERE user_id = ?1',
    )
      .bind(userId)
      .first<{ total: number }>();
    // Exactly one transition was recorded despite two deliveries.
    expect(events?.total).toBe(1);

    const stored = await env.DB.prepare('SELECT COUNT(*) AS total FROM webhook_events').first<{
      total: number;
    }>();
    expect(stored?.total).toBe(1);
  });

  it('applies a later cancellation and denies access afterwards', async () => {
    const userId = await seedStripeUser();
    const now = Math.floor(Date.now() / 1_000);

    await postStripeWebhook(subscriptionEvent());

    const cancelled = subscriptionEvent({
      type: 'customer.subscription.deleted',
      created: now + 10,
    });
    cancelled.data.object['status'] = 'canceled';
    cancelled.data.object['current_period_end'] = now - 1;
    await postStripeWebhook(cancelled);

    expect(await entitlementStatus(userId)).toBe('expired');
  });

  it('ignores an out-of-order delivery that is older than the stored state', async () => {
    const userId = await seedStripeUser();
    const now = Math.floor(Date.now() / 1_000);

    const recent = subscriptionEvent({ created: now });
    await postStripeWebhook(recent);

    const older = subscriptionEvent({ created: now - 600 });
    older.data.object['status'] = 'past_due';
    const response = await postStripeWebhook(older);
    expect(response.status).toBe(200);

    // The stale delivery must not downgrade newer state.
    expect(await entitlementStatus(userId)).toBe('active');
  });

  it('records an unattributable subscription as failed rather than dropping it', async () => {
    const event = subscriptionEvent();
    event.data.object['customer'] = 'cus_unknown';
    const response = await postStripeWebhook(event);
    expect(response.status).toBe(200);

    const row = await env.DB.prepare(
      'SELECT status, failure_reason FROM webhook_events WHERE event_id = ?1',
    )
      .bind(event.id)
      .first<{ status: string; failure_reason: string }>();
    expect(row?.status).toBe('failed');
    expect(row?.failure_reason).toBe('unattributable_customer');
  });

  it('marks events it deliberately does not handle as ignored', async () => {
    const event = subscriptionEvent({ type: 'invoice.paid' });
    const response = await postStripeWebhook(event);
    expect(response.status).toBe(200);
    const row = await env.DB.prepare('SELECT status FROM webhook_events WHERE event_id = ?1')
      .bind(event.id)
      .first<{ status: string }>();
    expect(row?.status).toBe('ignored');
  });

  it('prefers the user id in subscription metadata over the customer lookup', async () => {
    const userId = await seedStripeUser();
    const event = subscriptionEvent();
    event.data.object['customer'] = 'cus_not_linked';
    event.data.object['metadata'] = { user_id: userId };

    const response = await postStripeWebhook(event);
    expect(response.status).toBe(200);
    expect(await entitlementStatus(userId)).toBe('active');
  });
});

describe('App Store webhook', () => {
  it('rejects a notification with an unverifiable signed payload', async () => {
    const response = await SELF.fetch('https://api.test/v1/webhooks/appstore', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ signedPayload: 'aaa.bbb.ccc' }),
    });
    expect(response.status).toBe(401);

    const row = await env.DB.prepare('SELECT COUNT(*) AS total FROM webhook_events').first<{
      total: number;
    }>();
    expect(row?.total).toBe(0);
  });

  it('rejects a body with no signedPayload', async () => {
    const response = await SELF.fetch('https://api.test/v1/webhooks/appstore', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({}),
    });
    expect(response.status).toBe(400);
  });
});
