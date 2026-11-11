/**
 * Append-only audit events.
 */

export class AuditRepository {
  constructor(private readonly db: D1Database) {}

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
