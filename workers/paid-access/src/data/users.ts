/**
 * Users and their auth sessions.
 */

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

function toUser(row: UserRow): UserRecord {
  return {
    id: row.id,
    appleSub: row.apple_sub,
    email: row.email,
    role: row.role as UserRole,
    disabledAt: row.disabled_at,
  };
}

export class UserRepository {
  constructor(private readonly db: D1Database) {}

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
}
