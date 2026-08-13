/**
 * Entitlement, status and billing routes.
 */

import { ApiError, jsonResponse, readJson } from '../http.js';
import { requireSecret } from '../env.js';
import {
  applyUpdate,
  billingPeriod,
  effectiveStatus,
  grantsAccess,
  type Entitlement,
  type EntitlementSource,
  type EntitlementStatus,
} from '../entitlement.js';
import { StripeClient } from '../billing/stripe.js';
import {
  acceptedAppleEnvironments,
  appleRootCertificate,
  StoreKitError,
  storeKitEntitlementView,
  verifyStoreKitTransaction,
  type StoreKitRenewalPayload,
} from '../auth/storekit.js';
import { verifyAppleSignedJws } from '../auth/apple-jws.js';
import { policyDocument } from '../policy.js';
import type { AuthenticatedContext } from '../context.js';

const MAX_BILLING_BODY_BYTES = 32 * 1024;

/**
 * Writes an entitlement transition with bounded optimistic-concurrency retries.
 *
 * Concurrent webhook deliveries for the same subscription are common; retrying
 * on a version conflict keeps both writes correct without holding a long
 * transaction open.
 */
export async function transitionEntitlement(
  context: {
    repository: AuthenticatedContext['repository'];
    correlationId: string;
    nowSeconds: number;
  },
  input: {
    userId: string;
    status: EntitlementStatus;
    planId: string;
    source: EntitlementSource;
    sourceReference: string | null;
    currentPeriodStart: number | null;
    currentPeriodEnd: number | null;
    cancelAtPeriodEnd: boolean;
    revocationReason: string | null;
    sourceEventAt: number;
    reason: string;
    eventSource: 'stripe' | 'storekit' | 'manual' | 'system';
    sourceEventId: string | null;
  },
): Promise<{ applied: boolean; entitlement: Entitlement }> {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const current = await context.repository.ensureEntitlement(input.userId, context.nowSeconds);
    const outcome = applyUpdate(
      current,
      {
        status: input.status,
        planId: input.planId,
        source: input.source,
        sourceReference: input.sourceReference,
        currentPeriodStart: input.currentPeriodStart,
        currentPeriodEnd: input.currentPeriodEnd,
        cancelAtPeriodEnd: input.cancelAtPeriodEnd,
        revocationReason: input.revocationReason,
        sourceEventAt: input.sourceEventAt,
      },
      context.nowSeconds,
    );

    if (outcome.kind === 'stale') {
      return { applied: false, entitlement: outcome.current };
    }

    const written = await context.repository.writeEntitlementTransition({
      next: outcome.next,
      expectedVersion: current.version,
      fromStatus: current.status,
      reason: input.reason,
      eventSource: input.eventSource,
      sourceEventId: input.sourceEventId,
      correlationId: context.correlationId,
      nowSeconds: context.nowSeconds,
    });
    if (written) {
      return { applied: true, entitlement: outcome.next };
    }
  }
  throw new ApiError('conflict', 'Entitlement is being updated concurrently; retry');
}

export async function handleEntitlement(context: AuthenticatedContext): Promise<Response> {
  const entitlement = await context.repository.ensureEntitlement(
    context.session.userId,
    context.nowSeconds,
  );
  const period = billingPeriod(context.nowSeconds);
  const snapshot = await context.quota.status(context.session.userId, period, context.nowSeconds);
  const active = grantsAccess(entitlement, context.nowSeconds);

  return jsonResponse(
    {
      status: effectiveStatus(entitlement, context.nowSeconds),
      active,
      plan_id: entitlement.planId,
      source: entitlement.source,
      current_period_end: entitlement.currentPeriodEnd,
      cancel_at_period_end: entitlement.cancelAtPeriodEnd,
      paid_routing_available: active && !context.config.paidRoutingDisabled,
      usage: {
        period: snapshot.period,
        audio_seconds_used: snapshot.audioSecondsUsed,
        audio_seconds_limit: snapshot.audioSecondsLimit,
        tokens_used: snapshot.tokensUsed,
        tokens_limit: snapshot.tokensLimit,
        active_sessions: snapshot.activeSessions,
        max_concurrent_sessions: snapshot.maxConcurrentSessions,
      },
      policy: policyDocument(),
    },
    { correlationId: context.correlationId },
  );
}

// ---------------------------------------------------------------------------
// Stripe (direct-download macOS only)
// ---------------------------------------------------------------------------

interface CheckoutBody {
  channel?: unknown;
  price_id?: unknown;
}

/**
 * Picks which of the plan's prices Checkout opens with.
 *
 * The client may name one — that is how the yearly term is bought — but only
 * from the configured list, so a modified build cannot open Checkout against an
 * arbitrary price of its choosing. Omitting it takes the first configured price.
 */
function checkoutPriceFrom(body: CheckoutBody, allowed: readonly string[]): string {
  const first = allowed[0];
  if (first === undefined) {
    throw new ApiError('internal_error', 'No Stripe price is configured for this plan');
  }
  if (body.price_id === undefined || body.price_id === null) return first;
  if (typeof body.price_id !== 'string' || !allowed.includes(body.price_id)) {
    throw new ApiError('bad_request', 'That price is not sold by this plan');
  }
  return body.price_id;
}

/**
 * App Store builds must transact through StoreKit. The client also enforces
 * this, but the server refuses regardless of what the client claims, so a
 * modified build cannot route App Store users to Stripe.
 */
function requireDirectChannel(body: CheckoutBody): void {
  if (body.channel !== 'direct') {
    throw new ApiError(
      'forbidden',
      'Stripe billing is only available to the direct-download macOS build',
    );
  }
}

async function stripeCustomerFor(context: AuthenticatedContext): Promise<string> {
  const existing = await context.repository.findBillingCustomer(context.session.userId, 'stripe');
  if (existing !== null) return existing;

  const stripe = new StripeClient(
    requireSecret(context.env, 'STRIPE_SECRET_KEY'),
    context.config.upstreamTimeoutMs,
  );
  const user = await context.repository.findUserById(context.session.userId);
  const customer = await stripe.createCustomer({
    userId: context.session.userId,
    email: user?.email ?? null,
    // Stable key: retries reuse the same Stripe customer instead of creating one per attempt.
    idempotencyKey: `customer:${context.session.userId}`,
  });
  await context.repository.linkBillingCustomer({
    userId: context.session.userId,
    provider: 'stripe',
    providerCustomerId: customer.id,
    nowSeconds: context.nowSeconds,
  });
  return customer.id;
}

export async function handleStripeCheckout(
  request: Request,
  context: AuthenticatedContext,
): Promise<Response> {
  const body = await readJson<CheckoutBody>(request, MAX_BILLING_BODY_BYTES);
  requireDirectChannel(body);

  const customerId = await stripeCustomerFor(context);
  const stripe = new StripeClient(
    requireSecret(context.env, 'STRIPE_SECRET_KEY'),
    context.config.upstreamTimeoutMs,
  );
  const session = await stripe.createCheckoutSession({
    customerId,
    priceId: checkoutPriceFrom(body, context.config.stripePriceIds),
    userId: context.session.userId,
    successUrl: context.config.stripeSuccessUrl,
    cancelUrl: context.config.stripeCancelUrl,
    // Scoped to this request, not to the auth session: a session lives for weeks,
    // and Stripe replays the first checkout for any key it has already seen, so a
    // reusing key would hand back a stale (or already-completed) checkout URL.
    idempotencyKey: `checkout:${context.session.userId}:${context.correlationId}`,
  });

  await context.repository.recordAudit({
    userId: context.session.userId,
    actor: 'user',
    action: 'billing.stripe.checkout_created',
    outcome: 'allowed',
    detail: null,
    correlationId: context.correlationId,
    nowSeconds: context.nowSeconds,
  });

  return jsonResponse(
    { checkout_url: session.url },
    { correlationId: context.correlationId },
  );
}

export async function handleStripePortal(
  request: Request,
  context: AuthenticatedContext,
): Promise<Response> {
  const body = await readJson<CheckoutBody>(request, MAX_BILLING_BODY_BYTES);
  requireDirectChannel(body);

  const customerId = await context.repository.findBillingCustomer(
    context.session.userId,
    'stripe',
  );
  if (customerId === null) {
    throw new ApiError('not_found', 'No Stripe subscription exists for this account');
  }

  const stripe = new StripeClient(
    requireSecret(context.env, 'STRIPE_SECRET_KEY'),
    context.config.upstreamTimeoutMs,
  );
  const portal = await stripe.createPortalSession({
    customerId,
    returnUrl: context.config.stripePortalReturnUrl,
    idempotencyKey: `portal:${context.session.userId}:${context.nowSeconds}`,
  });

  return jsonResponse({ portal_url: portal.url }, { correlationId: context.correlationId });
}

// ---------------------------------------------------------------------------
// StoreKit (App Store builds)
// ---------------------------------------------------------------------------

interface StoreKitSyncBody {
  signed_transaction?: unknown;
  signed_renewal_info?: unknown;
}

export async function handleStoreKitSync(
  request: Request,
  context: AuthenticatedContext,
): Promise<Response> {
  const body = await readJson<StoreKitSyncBody>(request, MAX_BILLING_BODY_BYTES);
  if (typeof body.signed_transaction !== 'string' || body.signed_transaction.length > 16_384) {
    throw new ApiError('bad_request', 'Field signed_transaction is missing or malformed');
  }

  const rootDer = appleRootCertificate(context.env.APPSTORE_ROOT_CA_G3_BASE64);

  let transaction;
  try {
    transaction = await verifyStoreKitTransaction(
      body.signed_transaction,
      {
        rootDer,
        bundleIds: context.config.appleBundleIds,
        productIds: context.config.storeKitProductIds,
        environments: acceptedAppleEnvironments(context.config.environment),
        // Bind the receipt to the caller rather than to whoever syncs it first.
        appAccountToken: context.session.userId,
      },
      context.nowMs,
    );
  } catch (error) {
    const foreign = error instanceof StoreKitError && error.reason === 'not_this_account';
    context.logger.warn('billing.storekit.rejected', { foreign });
    await context.repository.recordAudit({
      userId: context.session.userId,
      actor: 'user',
      action: 'billing.storekit.sync',
      outcome: 'denied',
      detail: foreign ? 'transaction_belongs_to_another_account' : 'signed_transaction_rejected',
      correlationId: context.correlationId,
      nowSeconds: context.nowSeconds,
    });
    if (foreign) {
      throw new ApiError(
        'forbidden',
        'That subscription was purchased by a different account',
      );
    }
    throw new ApiError('unauthorized', 'Signed transaction could not be verified');
  }

  let renewal: StoreKitRenewalPayload | null = null;
  if (typeof body.signed_renewal_info === 'string' && body.signed_renewal_info.length <= 16_384) {
    try {
      renewal = await verifyAppleSignedJws<StoreKitRenewalPayload>(
        body.signed_renewal_info,
        rootDer,
        context.nowMs,
      );
    } catch {
      throw new ApiError('unauthorized', 'Signed renewal info could not be verified');
    }
    // Renewal info only describes the transaction it belongs to; accepting an
    // unrelated one would let a caller mix an active renewal into an expired
    // transaction.
    if (
      typeof renewal.originalTransactionId === 'string' &&
      renewal.originalTransactionId !== transaction.originalTransactionId
    ) {
      throw new ApiError('bad_request', 'Renewal info does not match the signed transaction');
    }
  }

  const view = storeKitEntitlementView(transaction, renewal, context.nowSeconds);

  // A subscription may only ever belong to one account. Without this, a shared
  // Apple ID receipt could grant paid access to unlimited accounts.
  const owner = await context.repository.findUserIdBySourceReference(
    'storekit',
    view.originalTransactionId,
  );
  if (owner !== null && owner !== context.session.userId) {
    throw new ApiError('conflict', 'This subscription is already linked to another account');
  }

  // The `owner` check above is advisory: two concurrent syncs can both pass it.
  // The unique constraint on the billing customer is the real guard, so a
  // constraint failure is reported as the same conflict rather than a 500.
  try {
    await context.repository.linkBillingCustomer({
      userId: context.session.userId,
      provider: 'storekit',
      providerCustomerId: view.originalTransactionId,
      nowSeconds: context.nowSeconds,
    });
  } catch (error) {
    if (error instanceof ApiError) throw error;
    context.logger.warn('billing.storekit.link_conflict');
    throw new ApiError('conflict', 'This subscription is already linked to another account');
  }

  const result = await transitionEntitlement(context, {
    userId: context.session.userId,
    status: view.status,
    planId: view.productId,
    source: 'storekit',
    sourceReference: view.originalTransactionId,
    currentPeriodStart: view.currentPeriodStart,
    currentPeriodEnd: view.currentPeriodEnd,
    cancelAtPeriodEnd: view.cancelAtPeriodEnd,
    revocationReason: view.revocationReason,
    sourceEventAt: view.sourceEventAt,
    reason: 'storekit_client_sync',
    eventSource: 'storekit',
    sourceEventId: transaction.transactionId ?? null,
  });

  context.logger.info('billing.storekit.synced', {
    applied: result.applied,
    status: result.entitlement.status,
  });

  return jsonResponse(
    {
      status: effectiveStatus(result.entitlement, context.nowSeconds),
      active: grantsAccess(result.entitlement, context.nowSeconds),
      current_period_end: result.entitlement.currentPeriodEnd,
      applied: result.applied,
    },
    { correlationId: context.correlationId },
  );
}
