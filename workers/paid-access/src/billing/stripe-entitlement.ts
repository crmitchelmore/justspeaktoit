/**
 * Stripe event → entitlement mapping.
 *
 * Pure policy: it reads a verified `customer.subscription.*` event, decides
 * whether it may move an entitlement and, if so, which transition to apply.
 * The webhook route owns delivery claims, persistence and logging; this module
 * owns only the decision, so every gate is testable without D1.
 */

import { StripeError, type StripeEvent } from './stripe.js';
import type { EntitlementStatus } from '../entitlement.js';

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

/** Lookups the decision needs, in the order it makes them. */
export interface StripeAttributionLookups {
  /** The user we mapped to this Stripe customer when the checkout was created. */
  findUserByCustomer(customerId: string): Promise<string | null>;
  /** The user whose entitlement currently names this subscription. */
  findSubscriptionOwner(subscriptionId: string): Promise<string | null>;
}

/** The entitlement transition a Stripe event asks for, ready for `transitionEntitlement`. */
export interface StripeEntitlementTransition {
  readonly userId: string;
  readonly status: EntitlementStatus;
  readonly planId: string;
  readonly source: 'stripe';
  readonly sourceReference: string;
  readonly currentPeriodStart: number | null;
  readonly currentPeriodEnd: number | null;
  readonly cancelAtPeriodEnd: boolean;
  readonly revocationReason: null;
  readonly sourceEventAt: number;
  readonly reason: string;
  readonly eventSource: 'stripe';
  readonly sourceEventId: string;
}

export type StripeEventDecision =
  /** Not a subscription event: nothing to do and nothing worth logging. */
  | { readonly kind: 'ignore'; readonly reason: null }
  /** A legitimate event for something this product does not own. */
  | { readonly kind: 'ignore'; readonly reason: 'price_not_in_plan' | 'subscription_not_current' }
  /** An event we cannot safely attribute; kept visible for reconciliation. */
  | { readonly kind: 'fail'; readonly reason: 'metadata_user_mismatch' | 'unattributable_customer' }
  | { readonly kind: 'apply'; readonly transition: StripeEntitlementTransition };

/**
 * Decides what a verified Stripe event may do to an entitlement.
 *
 * Throws `StripeError` for a subscription event it cannot parse, which the
 * route treats as transient so the provider's retry is processed.
 */
export async function decideStripeEvent(
  event: StripeEvent,
  planPriceIds: readonly string[],
  lookups: StripeAttributionLookups,
): Promise<StripeEventDecision> {
  const view = subscriptionView(event);
  if (view === null) return { kind: 'ignore', reason: null };

  // The subscription must bill on a price we sell. Stripe accounts routinely
  // carry other products, and a webhook for one of them must not silently
  // grant this product's entitlement.
  //
  // Only events that would grant or extend access are gated this way. A
  // cancellation must always be applied: `customer.subscription.deleted`
  // frequently arrives without expanded line items, and refusing it for
  // "wrong price" would leave a cancelled user entitled indefinitely — the
  // failure that costs us money rather than protecting it.
  const grantsAccess = view.status !== 'expired';
  if (grantsAccess && !view.priceIds.some((id) => planPriceIds.includes(id))) {
    return { kind: 'ignore', reason: 'price_not_in_plan' };
  }

  // Attribution comes from the customer mapping we wrote ourselves when the
  // checkout was created. `metadata.user_id` is writable from the Stripe
  // dashboard and by anything holding an API key, so it is only ever a
  // cross-check: if it disagrees with the mapping, something is wrong and the
  // safe move is to change nothing.
  const userId = await lookups.findUserByCustomer(view.customerId);
  if (userId !== null && view.userIdHint !== null && view.userIdHint !== userId) {
    return { kind: 'fail', reason: 'metadata_user_mismatch' };
  }

  // A cancellation skips the price gate, which leaves it able to expire an
  // entitlement belonging to a different subscription entirely — another
  // product on the same Stripe customer, or a previous subscription of ours.
  // It may only apply to the subscription the entitlement actually names.
  if (!grantsAccess && userId !== null) {
    const owner = await lookups.findSubscriptionOwner(view.subscriptionId);
    if (owner !== userId) return { kind: 'ignore', reason: 'subscription_not_current' };
  }

  // The subscription exists but we cannot attribute it. Recording this as
  // failed keeps it visible for reconciliation instead of silently dropping.
  if (userId === null) return { kind: 'fail', reason: 'unattributable_customer' };

  return {
    kind: 'apply',
    transition: {
      userId,
      status: view.status,
      // The price actually billed, not the plan's headline price, so a yearly
      // subscriber's record does not claim to be on the monthly plan.
      planId: view.priceIds.find((id) => planPriceIds.includes(id)) ?? planPriceIds[0] ?? 'unknown',
      source: 'stripe',
      sourceReference: view.subscriptionId,
      currentPeriodStart: view.currentPeriodStart,
      currentPeriodEnd: view.currentPeriodEnd,
      cancelAtPeriodEnd: view.cancelAtPeriodEnd,
      revocationReason: null,
      sourceEventAt: event.created,
      reason: event.type,
      eventSource: 'stripe',
      sourceEventId: event.id,
    },
  };
}
