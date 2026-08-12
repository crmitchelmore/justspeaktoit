/**
 * Entitlement state machine.
 *
 * Entitlement is the only thing that unlocks paid routing, so it is modelled
 * explicitly rather than inferred from billing payloads at each call site.
 * States are soft — revocation and expiry are recorded, never deleted — and
 * every transition is auditable.
 */

export const ENTITLEMENT_STATUSES = [
  'none',
  'trialing',
  'active',
  'grace',
  'past_due',
  'revoked',
  'expired',
] as const;

export type EntitlementStatus = (typeof ENTITLEMENT_STATUSES)[number];

export type EntitlementSource = 'stripe' | 'storekit' | 'manual';

export interface Entitlement {
  readonly id: string;
  readonly userId: string;
  readonly planId: string;
  readonly status: EntitlementStatus;
  readonly source: EntitlementSource;
  readonly sourceReference: string | null;
  readonly currentPeriodStart: number | null;
  readonly currentPeriodEnd: number | null;
  readonly cancelAtPeriodEnd: boolean;
  readonly revokedAt: number | null;
  readonly revocationReason: string | null;
  readonly version: number;
  readonly sourceEventAt: number | null;
}

/** Statuses that grant paid routing while the current period is still open. */
const GRANTING_STATUSES: ReadonlySet<EntitlementStatus> = new Set<EntitlementStatus>([
  'trialing',
  'active',
  'grace',
]);

/**
 * Whether an entitlement currently unlocks paid routing.
 *
 * Period expiry is evaluated here rather than trusted from the stored status,
 * so a webhook we never received cannot leave access switched on indefinitely.
 */
export function grantsAccess(entitlement: Entitlement | null, nowSeconds: number): boolean {
  if (entitlement === null) return false;
  if (entitlement.revokedAt !== null) return false;
  if (!GRANTING_STATUSES.has(entitlement.status)) return false;
  if (entitlement.currentPeriodEnd !== null && entitlement.currentPeriodEnd <= nowSeconds) {
    return false;
  }
  return true;
}

/**
 * The status a user should be shown, collapsing "stored status says active but
 * the period already ended" into `expired`.
 */
export function effectiveStatus(
  entitlement: Entitlement | null,
  nowSeconds: number,
): EntitlementStatus {
  if (entitlement === null) return 'none';
  if (entitlement.revokedAt !== null) return 'revoked';
  if (
    GRANTING_STATUSES.has(entitlement.status) &&
    entitlement.currentPeriodEnd !== null &&
    entitlement.currentPeriodEnd <= nowSeconds
  ) {
    return 'expired';
  }
  return entitlement.status;
}

/**
 * Legal transitions.
 *
 * `revoked` is terminal for a given subscription reference: recovering requires
 * a new purchase, which arrives with a new source reference. Everything else is
 * reachable from everything else because billing providers legitimately move
 * subscriptions between states in either direction.
 */
const ALLOWED_TRANSITIONS: Readonly<Record<EntitlementStatus, readonly EntitlementStatus[]>> = {
  none: ['trialing', 'active', 'past_due', 'grace', 'expired', 'revoked'],
  trialing: ['active', 'past_due', 'grace', 'expired', 'revoked'],
  active: ['active', 'past_due', 'grace', 'expired', 'revoked'],
  grace: ['active', 'past_due', 'expired', 'revoked'],
  past_due: ['active', 'grace', 'expired', 'revoked'],
  expired: ['active', 'trialing', 'past_due', 'grace', 'revoked'],
  revoked: [],
};

export function canTransition(from: EntitlementStatus, to: EntitlementStatus): boolean {
  if (from === to && from !== 'revoked') return true;
  return ALLOWED_TRANSITIONS[from].includes(to);
}

export class EntitlementTransitionError extends Error {
  readonly from: EntitlementStatus;
  readonly to: EntitlementStatus;

  constructor(from: EntitlementStatus, to: EntitlementStatus) {
    super(`Entitlement cannot move from ${from} to ${to}`);
    this.name = 'EntitlementTransitionError';
    this.from = from;
    this.to = to;
  }
}

export interface EntitlementUpdate {
  readonly status: EntitlementStatus;
  readonly planId: string;
  readonly source: EntitlementSource;
  readonly sourceReference: string | null;
  readonly currentPeriodStart: number | null;
  readonly currentPeriodEnd: number | null;
  readonly cancelAtPeriodEnd: boolean;
  readonly revocationReason: string | null;
  /** Provider event timestamp, used to discard out-of-order deliveries. */
  readonly sourceEventAt: number;
}

export type ApplyOutcome =
  | { readonly kind: 'applied'; readonly next: Entitlement }
  | { readonly kind: 'stale'; readonly current: Entitlement };

/**
 * Applies a provider update to an entitlement.
 *
 * Webhook deliveries are unordered and may be replayed, so an update carrying
 * an older `sourceEventAt` than the stored one is discarded instead of
 * overwriting newer state.
 */
export function applyUpdate(
  current: Entitlement,
  update: EntitlementUpdate,
  nowSeconds: number,
): ApplyOutcome {
  if (current.sourceEventAt !== null && update.sourceEventAt < current.sourceEventAt) {
    return { kind: 'stale', current };
  }
  if (!canTransition(current.status, update.status)) {
    throw new EntitlementTransitionError(current.status, update.status);
  }

  return {
    kind: 'applied',
    next: {
      ...current,
      planId: update.planId,
      status: update.status,
      source: update.source,
      sourceReference: update.sourceReference,
      currentPeriodStart: update.currentPeriodStart,
      currentPeriodEnd: update.currentPeriodEnd,
      cancelAtPeriodEnd: update.cancelAtPeriodEnd,
      revokedAt: update.status === 'revoked' ? (current.revokedAt ?? nowSeconds) : null,
      revocationReason: update.status === 'revoked' ? update.revocationReason : null,
      version: current.version + 1,
      sourceEventAt: update.sourceEventAt,
    },
  };
}

/** `YYYY-MM` billing period key used to partition the usage ledger and quota. */
export function billingPeriod(nowSeconds: number): string {
  const date = new Date(nowSeconds * 1000);
  const month = `${date.getUTCMonth() + 1}`.padStart(2, '0');
  return `${date.getUTCFullYear()}-${month}`;
}
