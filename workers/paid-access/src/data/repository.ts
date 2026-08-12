/**
 * D1 access.
 *
 * All SQL lives here so the constraints in `migrations/` and the queries that
 * rely on them stay side by side. Two rules hold throughout:
 *
 *   1. Transactions are short. D1 batches are used for the few multi-statement
 *      writes that must land together; nothing holds a transaction open across
 *      an upstream provider call.
 *   2. Uniqueness is the idempotency mechanism. Duplicate webhook deliveries
 *      and duplicate usage writes are rejected by the database, not by a
 *      read-then-write race in application code.
 */

import type {
  Entitlement,
  EntitlementSource,
  EntitlementStatus,
} from '../entitlement.js';
import type { UserRole } from '../auth/session.js';

export interface UserRecord {
  readonly id: string;
  readonly appleSub: string;
  readonly email: string | null;
  readonly role: UserRole;
  readonly disabledAt: number | null;
}

interface UserRow {
  id: string;
  apple_sub: string;
  email: string | null;
  role: string;
  disabled_at: number | null;
}

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

function toUser(row: UserRow): UserRecord {
  return {
    id: row.id,
    appleSub: row.apple_sub,
    email: row.email,
    role: row.role as UserRole,
    disabledAt: row.disabled_at,
  };
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

export class Repository {
  private readonly db: D1Database;

  constructor(db: D1Database) {
    this.db = db;
  }

  // -------------------------------------------------------------------------
  // Users and sessions
  // -------------------------------------------------------------------------

  /**
   * Finds or creates the user for an Apple subject.
   *
   * `ON CONFLICT (apple_sub) DO UPDATE` makes this safe under concurrent
   * sign-ins from two devices: the unique index decides the winner and both
   * requests read back the same row.
   */
  async upsertUserByAppleSub(
    appleSub: string,
    email: string | null,
    nowSeconds: number,
  ): Promise<UserRecord> {
    const id = crypto.randomUUID();
    const row = await this.db
      .prepare(
        `INSERT INTO users (id, apple_sub, email, role, created_at, updated_at)
         VALUES (?1, ?2, ?3, 'user', ?4, ?4)
         ON CONFLICT (apple_sub) DO UPDATE SET
           email = COALESCE(excluded.email, users.email),
           updated_at = ?4
         RETURNING id, apple_sub, email, role, disabled_at`,
      )
      .bind(id, appleSub, email, nowSeconds)
      .first<UserRow>();
    if (row === null) {
      throw new Error('Failed to upsert user');
    }
    return toUser(row);
  }

  async findUserById(userId: string): Promise<UserRecord | null> {
    const row = await this.db
      .prepare(`SELECT id, apple_sub, email, role, disabled_at FROM users WHERE id = ?1`)
      .bind(userId)
      .first<UserRow>();
    return row === null ? null : toUser(row);
  }

  async createAuthSession(input: {
    userId: string;
    refreshTokenHash: string;
    deviceLabel: string | null;
    createdAt: number;
    expiresAt: number;
  }): Promise<string> {
    const id = crypto.randomUUID();
    await this.db
      .prepare(
        `INSERT INTO auth_sessions
           (id, user_id, refresh_token_hash, device_label, created_at, expires_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6)`,
      )
      .bind(
        id,
        input.userId,
        input.refreshTokenHash,
        input.deviceLabel,
        input.createdAt,
        input.expiresAt,
      )
      .run();
    return id;
  }

  /**
   * Atomically consumes a refresh token: the `revoked_at IS NULL` predicate is
   * part of the UPDATE, so a replayed token cannot be redeemed twice even if
   * two requests arrive together.
   */
  async consumeRefreshToken(
    refreshTokenHash: string,
    nowSeconds: number,
  ): Promise<{ sessionId: string; userId: string } | null> {
    const row = await this.db
      .prepare(
        `UPDATE auth_sessions
            SET revoked_at = ?2, last_used_at = ?2
          WHERE refresh_token_hash = ?1
            AND revoked_at IS NULL
            AND expires_at > ?2
      RETURNING id, user_id`,
      )
      .bind(refreshTokenHash, nowSeconds)
      .first<{ id: string; user_id: string }>();
    return row === null ? null : { sessionId: row.id, userId: row.user_id };
  }

  async revokeSession(sessionId: string, nowSeconds: number): Promise<void> {
    await this.db
      .prepare(`UPDATE auth_sessions SET revoked_at = ?2 WHERE id = ?1 AND revoked_at IS NULL`)
      .bind(sessionId, nowSeconds)
      .run();
  }

  /**
   * Whether the auth session behind an access token is still live.
   *
   * Access tokens are short-lived but not revocable on their own, so sign-out
   * and refresh-token reuse detection only take effect if every authenticated
   * request re-checks the session row.
   */
  async isAuthSessionActive(sessionId: string, nowSeconds: number): Promise<boolean> {
    const row = await this.db
      .prepare(
        `SELECT id FROM auth_sessions
          WHERE id = ?1 AND revoked_at IS NULL AND expires_at > ?2`,
      )
      .bind(sessionId, nowSeconds)
      .first<{ id: string }>();
    return row !== null;
  }

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

  async findEntitlement(userId: string): Promise<Entitlement | null> {
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

  async findUserIdBySourceReference(
    source: EntitlementSource,
    sourceReference: string,
  ): Promise<string | null> {
    const row = await this.db
      .prepare(`SELECT user_id FROM entitlements WHERE source = ?1 AND source_reference = ?2`)
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
    fromStatus: EntitlementStatus;
    reason: string;
    eventSource: 'stripe' | 'storekit' | 'manual' | 'system';
    sourceEventId: string | null;
    correlationId: string;
    nowSeconds: number;
  }): Promise<boolean> {
    const { next } = input;
    const update = this.db
      .prepare(
        `UPDATE entitlements
            SET plan_id = ?2, status = ?3, source = ?4, source_reference = ?5,
                current_period_start = ?6, current_period_end = ?7,
                cancel_at_period_end = ?8, revoked_at = ?9, revocation_reason = ?10,
                version = ?11, source_event_at = ?12, updated_at = ?13
          WHERE user_id = ?1 AND version = ?14`,
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
      );

    const audit = this.db
      .prepare(
        `INSERT INTO entitlement_events
           (id, user_id, from_status, to_status, source, source_event_id,
            reason, correlation_id, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)`,
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
          WHERE provider = ?1 AND event_id = ?2`,
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

  // -------------------------------------------------------------------------
  // Usage ledger
  // -------------------------------------------------------------------------

  /**
   * Appends a usage row. Returns `false` when the idempotency key was already
   * recorded, so a retried client request is never double-charged.
   */
  async recordUsage(input: {
    userId: string;
    idempotencyKey: string;
    operation: 'live_transcription' | 'batch_transcription' | 'post_processing';
    provider: string;
    model: string;
    unitKind: 'audio_seconds' | 'tokens';
    units: number;
    billingPeriod: string;
    correlationId: string;
    nowSeconds: number;
  }): Promise<boolean> {
    if (!Number.isInteger(input.units) || input.units < 0) {
      throw new Error('Usage units must be a non-negative integer');
    }
    const result = await this.db
      .prepare(
        `INSERT INTO usage_ledger
           (id, user_id, idempotency_key, operation, provider, model,
            unit_kind, units, billing_period, correlation_id, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
         ON CONFLICT (user_id, idempotency_key) DO NOTHING`,
      )
      .bind(
        crypto.randomUUID(),
        input.userId,
        input.idempotencyKey,
        input.operation,
        input.provider,
        input.model,
        input.unitKind,
        input.units,
        input.billingPeriod,
        input.correlationId,
        input.nowSeconds,
      )
      .run();
    return (result.meta.changes ?? 0) > 0;
  }

  async usageTotals(
    userId: string,
    period: string,
  ): Promise<{ audioSeconds: number; tokens: number }> {
    const row = await this.db
      .prepare(
        `SELECT
           COALESCE(SUM(CASE WHEN unit_kind = 'audio_seconds' THEN units END), 0) AS audio_seconds,
           COALESCE(SUM(CASE WHEN unit_kind = 'tokens' THEN units END), 0) AS tokens
         FROM usage_ledger WHERE user_id = ?1 AND billing_period = ?2`,
      )
      .bind(userId, period)
      .first<{ audio_seconds: number; tokens: number }>();
    return { audioSeconds: row?.audio_seconds ?? 0, tokens: row?.tokens ?? 0 };
  }

  // -------------------------------------------------------------------------
  // Audit
  // -------------------------------------------------------------------------

  async recordAudit(input: {
    userId: string | null;
    actor: 'user' | 'system' | 'webhook';
    action: string;
    outcome: 'allowed' | 'denied' | 'error';
    detail: string | null;
    correlationId: string;
    nowSeconds: number;
  }): Promise<void> {
    await this.db
      .prepare(
        `INSERT INTO audit_events
           (id, user_id, actor, action, outcome, detail, correlation_id, created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)`,
      )
      .bind(
        crypto.randomUUID(),
        input.userId,
        input.actor,
        input.action,
        input.outcome,
        input.detail,
        input.correlationId,
        input.nowSeconds,
      )
      .run();
  }
}
