/**
 * The one write path for entitlement changes from billing providers.
 *
 * StoreKit sync and both provider webhooks move an entitlement through here,
 * so the state machine (`applyUpdate`) and the version check always run.
 */

import { ApiError } from '../http.js';
import {
  applyUpdate,
  type Entitlement,
  type EntitlementSource,
  type EntitlementStatus,
} from '../entitlement.js';
import type { AuthenticatedContext } from '../context.js';

export interface EntitlementTransitionInput {
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
}

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
  input: EntitlementTransitionInput,
): Promise<{ applied: boolean; entitlement: Entitlement }> {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    const current = await context.repository.entitlements.ensureSubscription(
      input.userId, input.source, input.sourceReference, context.nowSeconds,
    );
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
      return { applied: false, entitlement: (await context.repository.entitlements.findEntitlement(input.userId, context.nowSeconds))! };
    }

    const written = await context.repository.entitlements.writeEntitlementTransition({
      next: outcome.next,
      expectedVersion: current.version,
      scopeToSubscription: true,
      fromStatus: current.status,
      reason: input.reason,
      eventSource: input.eventSource,
      sourceEventId: input.sourceEventId,
      correlationId: context.correlationId,
      nowSeconds: context.nowSeconds,
    });
    if (written) {
      return { applied: true, entitlement: (await context.repository.entitlements.findEntitlement(input.userId, context.nowSeconds))! };
    }
  }
  throw new ApiError('conflict', 'Entitlement is being updated concurrently; retry');
}
