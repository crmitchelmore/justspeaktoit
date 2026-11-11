/**
 * Paid request claims and the permanent usage ledger. They share one module
 * because a claim is reconciled against the ledger before any spend: the
 * ledger, not the expiring claim, is the metering identity.
 */

export type PaidOperationName = 'live_transcription' | 'batch_transcription' | 'post_processing';

export type RequestClaimStatus = 'in_flight' | 'completed';

export interface RequestClaim {
  readonly operation: PaidOperationName;
  readonly status: RequestClaimStatus;
}

/**
 * How long an operational request claim is remembered.
 *
 * Completed charges remain deduplicated by the permanent usage ledger after
 * claims expire. A deliberate new attempt already uses a fresh client key.
 */
export const REQUEST_CLAIM_TTL_SECONDS = 24 * 60 * 60;

export class UsageRepository {
  constructor(private readonly db: D1Database) {}

  // -------------------------------------------------------------------------
  // Request idempotency
  // -------------------------------------------------------------------------

  /**
   * Claims an `Idempotency-Key` for a paid request.
   *
   * Returns `null` when this caller now owns the request, or the existing claim
   * when somebody got there first. Claiming happens before any quota is reserved
   * and before the vendor is called, which is the whole point: a retry that
   * arrives while the first attempt is still running, or after it finished, must
   * not buy a second upstream call.
   */
  async pruneExpiredRequestClaims(nowSeconds: number): Promise<number> {
    const result = await this.db.prepare(
      `DELETE FROM request_claims WHERE id IN
       (SELECT id FROM request_claims WHERE expires_at <= ?1 ORDER BY expires_at LIMIT 1000)`,
    ).bind(nowSeconds).run();
    return result.meta.changes;
  }

  async claimRequest(input: {
    userId: string;
    idempotencyKey: string;
    operation: PaidOperationName;
    correlationId: string;
    nowSeconds: number;
  }): Promise<RequestClaim | null> {
    // Expiry releases operational claims, not the permanent metering identity.
    // Reconcile with the existing ledger before reserving quota or dispatching
    // another provider call. No transcript or response content is retained.
    const metered = await this.meteredRequest(input.userId, input.idempotencyKey);
    if (metered !== null) return metered;
    await this.db
      .prepare(
        `DELETE FROM request_claims
          WHERE user_id = ?1 AND idempotency_key = ?2 AND expires_at <= ?3`,
      )
      .bind(input.userId, input.idempotencyKey, input.nowSeconds)
      .run();

    const result = await this.db
      .prepare(
        `INSERT INTO request_claims
           (id, user_id, idempotency_key, operation, status, correlation_id,
            created_at, expires_at)
         SELECT ?1, ?2, ?3, ?4, 'in_flight', ?5, ?6, ?7
          WHERE NOT EXISTS (SELECT 1 FROM usage_ledger
                            WHERE user_id = ?2 AND idempotency_key = ?3)
         ON CONFLICT (user_id, idempotency_key) DO NOTHING`,
      )
      .bind(
        crypto.randomUUID(),
        input.userId,
        input.idempotencyKey,
        input.operation,
        input.correlationId,
        input.nowSeconds,
        input.nowSeconds + REQUEST_CLAIM_TTL_SECONDS,
      )
      .run();

    if ((result.meta.changes ?? 0) > 0) return null;

    // A previous owner may have settled between the first read and insert.
    const settled = await this.meteredRequest(input.userId, input.idempotencyKey);
    if (settled !== null) return settled;

    const row = await this.db
      .prepare(
        `SELECT operation, status FROM request_claims
          WHERE user_id = ?1 AND idempotency_key = ?2 AND expires_at > ?3`,
      )
      .bind(input.userId, input.idempotencyKey, input.nowSeconds)
      .first<{ operation: string; status: string }>();
    if (row === null) {
      // The winning claim was rolled back between the insert and this read.
      // Treating that as "in flight" is the safe answer: the caller declines
      // rather than racing a request it cannot see.
      return { operation: input.operation, status: 'in_flight' };
    }
    return {
      operation: row.operation as PaidOperationName,
      status: row.status as RequestClaimStatus,
    };
  }

  private async meteredRequest(userId: string, idempotencyKey: string): Promise<RequestClaim | null> {
    const row = await this.db.prepare(
      'SELECT operation FROM usage_ledger WHERE user_id = ?1 AND idempotency_key = ?2',
    ).bind(userId, idempotencyKey).first<{ operation: PaidOperationName }>();
    return row === null ? null : { operation: row.operation, status: 'completed' };
  }

  /**
   * Marks the claimed request as finished.
   *
   * Records that the work happened, never what it produced: a later retry is
   * told the request already completed rather than being handed a replayed
   * transcript, because storing the response would make this table a store of
   * dictated text.
   */
  async completeRequestClaim(input: {
    userId: string;
    idempotencyKey: string;
    nowSeconds: number;
  }): Promise<void> {
    await this.db
      .prepare(
        `UPDATE request_claims
            SET status = 'completed', completed_at = ?3
          WHERE user_id = ?1 AND idempotency_key = ?2 AND status = 'in_flight'`,
      )
      .bind(input.userId, input.idempotencyKey, input.nowSeconds)
      .run();
  }

  /**
   * Drops a claim whose request failed, so the client's retry is served rather
   * than answered as a duplicate for ever. Only an `in_flight` claim is removed;
   * a completed one stays put until expiry. The permanent usage ledger continues
   * to decline metered retries after the operational claim is pruned.
   */
  async releaseRequestClaim(input: { userId: string; idempotencyKey: string }): Promise<void> {
    await this.db
      .prepare(
        `DELETE FROM request_claims
          WHERE user_id = ?1 AND idempotency_key = ?2 AND status = 'in_flight'`,
      )
      .bind(input.userId, input.idempotencyKey)
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
    operation: PaidOperationName;
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

  /** Exact immutable projection of a quota DO receipt; retries never create new identity. */
  async reconcileUsage(input: {
    ledgerEntryId: string; userId: string; idempotencyKey: string; operation: PaidOperationName;
    provider: string; model: string; unitKind: 'audio_seconds' | 'tokens'; units: number;
    billingPeriod: string; correlationId: string; measuredAt: number;
  }): Promise<'matched' | 'conflict'> {
    await this.db.prepare(
      `INSERT INTO usage_ledger
         (id, user_id, idempotency_key, operation, provider, model,
          unit_kind, units, billing_period, correlation_id, created_at)
       VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
       ON CONFLICT (user_id, idempotency_key) DO NOTHING`,
    ).bind(input.ledgerEntryId, input.userId, input.idempotencyKey, input.operation,
      input.provider, input.model, input.unitKind, input.units, input.billingPeriod,
      input.correlationId, input.measuredAt).run();
    const row = await this.db.prepare(
      `SELECT id, operation, provider, model, unit_kind, units, billing_period, correlation_id, created_at
       FROM usage_ledger WHERE user_id = ?1 AND idempotency_key = ?2`,
    ).bind(input.userId, input.idempotencyKey).first<Record<string, unknown>>();
    return row !== null && row.id === input.ledgerEntryId && row.operation === input.operation
      && row.provider === input.provider && row.model === input.model && row.unit_kind === input.unitKind
      && row.units === input.units && row.billing_period === input.billingPeriod
      && row.correlation_id === input.correlationId && row.created_at === input.measuredAt
      ? 'matched' : 'conflict';
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
}
