/**
 * Stripe integration.
 *
 * Only the direct-download macOS build uses Stripe; App Store builds must use
 * StoreKit. That policy is enforced server-side in the route handlers, not just
 * in the client UI.
 *
 * The Stripe SDK is not used: it is heavy for the Workers runtime and we need
 * only three calls. Requests go through `fetch` with an explicit timeout, and
 * every mutating call carries an idempotency key so a retry cannot create a
 * second checkout session or subscription.
 */

import { ApiError, fetchWithTimeout } from '../http.js';
import { hmacSha256Hex, sha256Hex, timingSafeEqual } from '../crypto.js';
import type { EntitlementStatus } from '../entitlement.js';

const STRIPE_API = 'https://api.stripe.com/v1';
const STRIPE_VERSION = '2025-06-30.basil';

export class StripeError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'StripeError';
  }
}

interface StripeRequest {
  readonly path: string;
  readonly form: Record<string, string>;
  readonly idempotencyKey: string;
}

export class StripeClient {
  private readonly secretKey: string;
  private readonly timeoutMs: number;

  constructor(secretKey: string, timeoutMs: number) {
    this.secretKey = secretKey;
    this.timeoutMs = timeoutMs;
  }

  private async post<T>(request: StripeRequest): Promise<T> {
    const body = new URLSearchParams(request.form).toString();
    const response = await fetchWithTimeout(
      `${STRIPE_API}${request.path}`,
      {
        method: 'POST',
        headers: {
          authorization: `Bearer ${this.secretKey}`,
          'content-type': 'application/x-www-form-urlencoded',
          'stripe-version': STRIPE_VERSION,
          // Stripe deduplicates on this for 24 hours, which is what makes a
          // client retry safe.
          'idempotency-key': request.idempotencyKey,
        },
        body,
      },
      this.timeoutMs,
    );

    if (!response.ok) {
      // Stripe error bodies can echo customer email; never surface or log them.
      throw new ApiError('upstream_error', `Stripe request failed with status ${response.status}`);
    }
    return (await response.json());
  }

  async createCustomer(input: {
    userId: string;
    email: string | null;
    idempotencyKey: string;
  }): Promise<{ id: string }> {
    const form: Record<string, string> = { 'metadata[user_id]': input.userId };
    if (input.email !== null) {
      form['email'] = input.email;
    }
    return this.post<{ id: string }>({
      path: '/customers',
      form,
      idempotencyKey: input.idempotencyKey,
    });
  }

  async createCheckoutSession(input: {
    customerId: string;
    priceId: string;
    userId: string;
    successUrl: string;
    cancelUrl: string;
    idempotencyKey: string;
  }): Promise<{ id: string; url: string }> {
    return this.post<{ id: string; url: string }>({
      path: '/checkout/sessions',
      form: {
        mode: 'subscription',
        customer: input.customerId,
        'line_items[0][price]': input.priceId,
        'line_items[0][quantity]': '1',
        success_url: input.successUrl,
        cancel_url: input.cancelUrl,
        client_reference_id: input.userId,
        'subscription_data[metadata][user_id]': input.userId,
        'metadata[user_id]': input.userId,
      },
      idempotencyKey: input.idempotencyKey,
    });
  }

  async createPortalSession(input: {
    customerId: string;
    returnUrl: string;
    idempotencyKey: string;
  }): Promise<{ url: string }> {
    return this.post<{ url: string }>({
      path: '/billing_portal/sessions',
      form: { customer: input.customerId, return_url: input.returnUrl },
      idempotencyKey: input.idempotencyKey,
    });
  }
}

// ---------------------------------------------------------------------------
// Webhook signature verification
// ---------------------------------------------------------------------------

export interface StripeEvent {
  readonly id: string;
  readonly type: string;
  readonly created: number;
  readonly data: { readonly object: Record<string, unknown> };
}

const DEFAULT_TOLERANCE_SECONDS = 300;

/**
 * Verifies a `Stripe-Signature` header.
 *
 * Webhooks authenticate with their own shared secret — they never present a
 * user session — so this is the only trust path for the webhook endpoint.
 * The timestamp is bound into the signed material, so replaying an old but
 * genuinely signed delivery outside the tolerance window fails.
 */
export async function verifyStripeSignature(
  payload: string,
  signatureHeader: string | null,
  secret: string,
  nowSeconds: number,
  toleranceSeconds: number = DEFAULT_TOLERANCE_SECONDS,
): Promise<StripeEvent> {
  if (signatureHeader === null || signatureHeader.length === 0) {
    throw new StripeError('Missing Stripe-Signature header');
  }

  let timestamp: number | null = null;
  const signatures: string[] = [];
  for (const part of signatureHeader.split(',')) {
    const [key, value] = part.trim().split('=', 2);
    if (key === 't' && value !== undefined) {
      timestamp = Number.parseInt(value, 10);
    } else if (key === 'v1' && value !== undefined) {
      signatures.push(value);
    }
  }

  if (timestamp === null || !Number.isFinite(timestamp)) {
    throw new StripeError('Stripe-Signature header has no timestamp');
  }
  if (signatures.length === 0) {
    throw new StripeError('Stripe-Signature header has no v1 signature');
  }
  if (Math.abs(nowSeconds - timestamp) > toleranceSeconds) {
    throw new StripeError('Stripe-Signature timestamp is outside the tolerance window');
  }

  const expected = await hmacSha256Hex(secret, `${timestamp}.${payload}`);
  const matched = signatures.some((candidate) => timingSafeEqual(expected, candidate));
  if (!matched) {
    throw new StripeError('Stripe-Signature does not match the payload');
  }

  let event: StripeEvent;
  try {
    event = JSON.parse(payload) as StripeEvent;
  } catch {
    throw new StripeError('Stripe webhook payload is not valid JSON');
  }
  if (typeof event.id !== 'string' || typeof event.type !== 'string') {
    throw new StripeError('Stripe webhook payload is missing id or type');
  }
  return event;
}

export function payloadDigest(payload: string): Promise<string> {
  return sha256Hex(payload);
}

// ---------------------------------------------------------------------------
// Event → entitlement mapping
// ---------------------------------------------------------------------------

export interface StripeSubscriptionView {
  readonly subscriptionId: string;
  readonly customerId: string;
  readonly status: EntitlementStatus;
  readonly currentPeriodStart: number | null;
  readonly currentPeriodEnd: number | null;
  readonly cancelAtPeriodEnd: boolean;
  /**
   * `metadata.user_id`, as Stripe echoed it back.
   *
   * A hint and nothing more: metadata is writable from the Stripe dashboard and
   * by anything holding an API key, so it is cross-checked against the stored
   * customer mapping rather than believed.
   */
  readonly userIdHint: string | null;
  /** Every price the subscription bills on, for checking against our own plan. */
  readonly priceIds: readonly string[];
}

const STATUS_MAP: Readonly<Record<string, EntitlementStatus>> = {
  trialing: 'trialing',
  active: 'active',
  past_due: 'past_due',
  unpaid: 'past_due',
  incomplete: 'past_due',
  incomplete_expired: 'expired',
  canceled: 'expired',
  paused: 'expired',
};

function readNumber(source: Record<string, unknown>, key: string): number | null {
  const value = source[key];
  return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

/**
 * Extracts the entitlement-relevant fields from a `customer.subscription.*`
 * object. Returns `null` for events we deliberately ignore, which the caller
 * records as `ignored` rather than `failed`.
 */
export function subscriptionView(event: StripeEvent): StripeSubscriptionView | null {
  if (!event.type.startsWith('customer.subscription.')) {
    return null;
  }
  const object = event.data.object;
  const subscriptionId = object['id'];
  const customer = object['customer'];
  const status = object['status'];
  if (typeof subscriptionId !== 'string' || typeof customer !== 'string' || typeof status !== 'string') {
    throw new StripeError('Subscription event is missing id, customer or status');
  }

  const mapped = STATUS_MAP[status];
  if (mapped === undefined) {
    throw new StripeError(`Unhandled Stripe subscription status: ${status}`);
  }

  const metadata = object['metadata'];
  const rawUserIdHint =
    typeof metadata === 'object' && metadata !== null
      ? (metadata as Record<string, unknown>)['user_id']
      : undefined;
  // Metadata is free-form JSON from an external system; a number, an object or
  // an array here must not be smuggled through as a user id.
  const userIdHint = typeof rawUserIdHint === 'string' && rawUserIdHint.length > 0
    ? rawUserIdHint
    : null;

  // Stripe moved period boundaries onto the subscription item in newer API
  // versions; read both shapes so an account on either version works.
  const items = object['items'];
  const itemRows: readonly Record<string, unknown>[] =
    typeof items === 'object' && items !== null && Array.isArray((items as { data?: unknown }).data)
      ? ((items as { data: unknown[] }).data.filter(
          (entry): entry is Record<string, unknown> => typeof entry === 'object' && entry !== null,
        ))
      : [];
  const firstItem = itemRows[0] ?? null;

  return {
    subscriptionId,
    customerId: customer,
    status: event.type === 'customer.subscription.deleted' ? 'expired' : mapped,
    currentPeriodStart:
      readNumber(object, 'current_period_start') ??
      (firstItem === null ? null : readNumber(firstItem, 'current_period_start')),
    currentPeriodEnd:
      readNumber(object, 'current_period_end') ??
      (firstItem === null ? null : readNumber(firstItem, 'current_period_end')),
    cancelAtPeriodEnd: object['cancel_at_period_end'] === true,
    userIdHint,
    priceIds: itemRows
      .map((item) => {
        const price = item['price'];
        if (typeof price === 'string') return price;
        if (typeof price === 'object' && price !== null) {
          const id = (price as Record<string, unknown>)['id'];
          return typeof id === 'string' ? id : null;
        }
        return null;
      })
      .filter((id): id is string => id !== null),
  };
}
