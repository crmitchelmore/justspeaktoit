/**
 * Entitlements and the billing state that drives them: billing customers,
 * per-source subscription states and webhook delivery idempotency.
 */

import type {
  Entitlement,
  EntitlementSource,
  EntitlementStatus,
} from '../entitlement.js';
import { grantsAccess } from '../entitlement.js';

interface EntitlementRow {
  id: string;
  user_id: string;
  plan_id: string;
  status: string;
  source: string;
  source_reference: string | null;
  current_period_start: number | null;
  current_period_end: number | null;
  cancel_at_period_end: number;
  revoked_at: number | null;
  revocation_reason: string | null;
  version: number;
  source_event_at: number | null;
}

function toEntitlement(row: EntitlementRow): Entitlement {
  return {
    id: row.id,
    userId: row.user_id,
    planId: row.plan_id,
    status: row.status as EntitlementStatus,
    source: row.source as EntitlementSource,
    sourceReference: row.source_reference,
    currentPeriodStart: row.current_period_start,
    currentPeriodEnd: row.current_period_end,
    cancelAtPeriodEnd: row.cancel_at_period_end === 1,
    revokedAt: row.revoked_at,
    revocationReason: row.revocation_reason,
    version: row.version,
    sourceEventAt: row.source_event_at,
  };
}

export class EntitlementRepository {
  constructor(private readonly db: D1Database) {}

  // -------------------------------------------------------------------------
  // Billing customers
  // -------------------------------------------------------------------------

  async linkBillingCustomer(input: {
    userId: string;
    provider: 'stripe' | 'storekit';
    providerCustomerId: string;
    nowSeconds: number;
  }): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO billing_customers
           (id, user_id, provider, provider_customer_id, created_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?5)
         ON CONFLICT (user_id, provider) DO UPDATE SET
           provider_customer_id = excluded.provider_customer_id,
           updated_at = excluded.updated_at`,
      )
      .bind(
        crypto.randomUUID(),
        input.userId,
        input.provider,
        input.providerCustomerId,
        input.nowSeconds,
      )
      .run();
  }

  async findBillingCustomer(
    userId: string,
    provider: 'stripe' | 'storekit',
  ): Promise<string | null> {
    const row = await this.db
      .prepare(
        `SELECT provider_customer_id FROM billing_customers WHERE user_id = ?1 AND provider = ?2`,
      )
      .bind(userId, provider)
      .first<{ provider_customer_id: string }>();
    return row?.provider_customer_id ?? null;
  }

  async findUserByBillingCustomer(
    provider: 'stripe' | 'storekit',
    providerCustomerId: string,
  ): Promise<string | null> {
    const row = await this.db
      .prepare(
        `SELECT user_id FROM billing_customers WHERE provider = ?1 AND provider_customer_id = ?2`,
      )
      .bind(provider, providerCustomerId)
      .first<{ user_id: string }>();
    return row?.user_id ?? null;
  }

  // -------------------------------------------------------------------------
  // Entitlements
  // -------------------------------------------------------------------------

  private async findLegacyEntitlement(userId: string): Promise<Entitlement | null> {
    const row = await this.db
      .prepare(
        `SELECT id, user_id, plan_id, status, source, source_reference,
                current_period_start, current_period_end, cancel_at_period_end,
                revoked_at, revocation_reason, version, source_event_at
           FROM entitlements WHERE user_id = ?1`,
      )
      .bind(userId)
      .first<EntitlementRow>();
    return row === null ? null : toEntitlement(row);
  }

  async findEntitlement(userId: string, nowSeconds = Math.floor(Date.now() / 1000)): Promise<Entitlement | null> {
    const result = await this.db.prepare('SELECT * FROM subscription_states WHERE user_id = ?1')
      .bind(userId).all<EntitlementRow>();
    const states = result.results.map(toEntitlement);
    const legacy = await this.findLegacyEntitlement(userId);
    // Preserve a legacy purchase until it has a source-specific record.
    // The new table is authoritative once that purchase has been migrated.
    if (legacy !== null && !states.some((state) =>
      state.source === legacy.source && state.sourceReference === legacy.sourceReference)) states.push(legacy);
    const active = states.filter((state) => grantsAccess(state, nowSeconds));
    const candidates = active.length > 0 ? active : states;
    candidates.sort((left, right) => {
      if (active.length > 0) {
        const end = (right.currentPeriodEnd ?? Number.MAX_SAFE_INTEGER) -
          (left.currentPeriodEnd ?? Number.MAX_SAFE_INTEGER);
        if (end !== 0) return end;
      }
      return (right.sourceEventAt ?? 0) - (left.sourceEventAt ?? 0) || left.id.localeCompare(right.id);
    });
    return candidates[0] ?? null;
  }

  async ensureSubscription(userId: string, source: EntitlementSource,
    sourceReference: string | null, nowSeconds: number): Promise<Entitlement> {
    await this.ensureEntitlement(userId, nowSeconds);
    // Seed the matching legacy purchase, retaining its status and event clock.
    await this.db.prepare(`INSERT OR IGNORE INTO subscription_states SELECT * FROM entitlements
      WHERE user_id = ?1 AND source = ?2 AND source_reference IS ?3`)
      .bind(userId, source, sourceReference).run();
    await this.db.prepare(`INSERT INTO subscription_states
      (id, user_id, plan_id, status, source, source_reference, created_at, updated_at)
      VALUES (?1, ?2, 'free', 'none', ?3, ?4, ?5, ?5) ON CONFLICT DO NOTHING`)
      .bind(crypto.randomUUID(), userId, source, sourceReference, nowSeconds).run();
    const row = await this.db.prepare(`SELECT * FROM subscription_states
      WHERE user_id = ?1 AND source = ?2 AND source_reference IS ?3`)
      .bind(userId, source, sourceReference).first<EntitlementRow>();
    if (row === null) throw new Error('Subscription belongs to another account');
    return toEntitlement(row);
  }

  async findUserIdBySourceReference(
    source: EntitlementSource,
    sourceReference: string,
  ): Promise<string | null> {
    const row = await this.db
      .prepare(`SELECT user_id FROM subscription_states WHERE source = ?1 AND source_reference = ?2
         UNION SELECT user_id FROM entitlements WHERE source = ?1 AND source_reference = ?2 LIMIT 1`)
      .bind(source, sourceReference)
      .first<{ user_id: string }>();
    return row?.user_id ?? null;
  }

  /** Creates the implicit `none` entitlement a user starts life with. */
  async ensureEntitlement(userId: string, nowSeconds: number): Promise<Entitlement> {
    const existing = await this.findEntitlement(userId);
    if (existing !== null) return existing;

    await this.db
      .prepare(
        `INSERT INTO entitlements
           (id, user_id, plan_id, status, source, created_at, updated_at)
         VALUES (?1, ?2, 'free', 'none', 'manual', ?3, ?3)
         ON CONFLICT (user_id) DO NOTHING`,
      )
      .bind(crypto.randomUUID(), userId, nowSeconds)
      .run();

    const created = await this.findEntitlement(userId);
    if (created === null) {
      throw new Error('Failed to create entitlement');
    }
    return created;
  }

  /**
   * Persists an entitlement transition together with its audit event.
   *
   * The `version = ?` predicate provides optimistic concurrency: a concurrent
   * writer that already advanced the row causes zero rows to be updated, and
   * the caller retries with fresh state rather than clobbering it.
   */
  async writeEntitlementTransition(input: {
    next: Entitlement;
    expectedVersion: number;
    scopeToSubscription?: boolean;
    fromStatus: EntitlementStatus;
    reason: string;
    eventSource: 'stripe' | 'storekit' | 'manual' | 'system';
    sourceEventId: string | null;
    correlationId: string;
    nowSeconds: number;
  }): Promise<boolean> {
    const { next } = input;
    const table = input.scopeToSubscription ? 'subscription_states' : 'entitlements';
    const update = this.db
      .prepare(
        `UPDATE ${table}
            SET plan_id = ?2, status = ?3, source = ?4, source_reference = ?5,
                current_period_start = ?6, current_period_end = ?7,
                cancel_at_period_end = ?8, revoked_at = ?9, revocation_reason = ?10,
                version = ?11, source_event_at = ?12, updated_at = ?13
          WHERE user_id = ?1 AND version = ?14
            AND (?15 = 0 OR (source = ?16 AND source_reference IS ?17))`,
      )
      .bind(
        next.userId,
        next.planId,
        next.status,
        next.source,
        next.sourceReference,
        next.currentPeriodStart,
        next.currentPeriodEnd,
        next.cancelAtPeriodEnd ? 1 : 0,
        next.revokedAt,
        next.revocationReason,
        next.version,
        next.sourceEventAt,
        input.nowSeconds,
        input.expectedVersion,
        input.scopeToSubscription ? 1 : 0,
        next.source,
        next.sourceReference,
      );

    // changes() reports the row count of the immediately preceding statement
    // in this batch's transaction, so the append-only audit row is written
    // only when the optimistic UPDATE actually applied. A version-conflict
    // retry therefore cannot record a transition that never occurred.
    const audit = this.db
      .prepare(
        `INSERT INTO entitlement_events
           (id, user_id, from_status, to_status, source, source_event_id,
            reason, correlation_id, created_at)
         SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9
          WHERE changes() > 0`,
      )
      .bind(
        crypto.randomUUID(),
        next.userId,
        input.fromStatus,
        next.status,
        input.eventSource,
        input.sourceEventId,
        input.reason,
        input.correlationId,
        input.nowSeconds,
      );

    const [updateResult] = await this.db.batch([update, audit]);
    return (updateResult?.meta.changes ?? 0) > 0;
  }

  // -------------------------------------------------------------------------
  // Webhook idempotency
  // -------------------------------------------------------------------------

  /**
   * Claims a webhook delivery for processing.
   *
   * Returns `false` when the event was already recorded, which is the whole
   * idempotency guarantee: the UNIQUE(provider, event_id) index means only one
   * concurrent delivery can win.
   */
  async claimWebhookEvent(input: {
    provider: 'stripe' | 'appstore';
    eventId: string;
    eventType: string;
    payloadDigest: string;
    correlationId: string;
    nowSeconds: number;
  }): Promise<boolean> {
    const result = await this.db
      .prepare(
        `INSERT INTO webhook_events
           (id, provider, event_id, event_type, status, payload_digest, correlation_id, received_at)
         VALUES (?1, ?2, ?3, ?4, 'received', ?5, ?6, ?7)
         ON CONFLICT (provider, event_id) DO NOTHING`,
      )
      .bind(
        `${input.provider}:${input.eventId}`,
        input.provider,
        input.eventId,
        input.eventType,
        input.payloadDigest,
        input.correlationId,
        input.nowSeconds,
      )
      .run();
    return (result.meta.changes ?? 0) > 0;
  }

  /**
   * Reopens a claimed webhook delivery so the provider's retry is processed
   * rather than answered as a duplicate. Only a delivery that is still
   * `received` (never completed) is removed, so a processed event stays
   * deduplicated for ever.
   */
  async releaseWebhookClaim(input: {
    provider: 'stripe' | 'appstore';
    eventId: string;
  }): Promise<void> {
    await this.db
      .prepare(
        `DELETE FROM webhook_events
          WHERE provider = ?1 AND event_id = ?2 AND status = 'received'`,
      )
      .bind(input.provider, input.eventId)
      .run();
  }

  async completeWebhookEvent(input: {
    provider: 'stripe' | 'appstore';
    eventId: string;
    status: 'processed' | 'ignored' | 'failed';
    failureReason: string | null;
    nowSeconds: number;
  }): Promise<void> {
    await this.db
      .prepare(
        `UPDATE webhook_events
            SET status = ?3, processed_at = ?4, failure_reason = ?5
          WHERE provider = ?1 AND event_id = ?2 AND status = 'received'`,
      )
      .bind(
        input.provider,
        input.eventId,
        input.status,
        input.nowSeconds,
        input.failureReason,
      )
      .run();
  }
}
