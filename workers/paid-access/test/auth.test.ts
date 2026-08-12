import { env, SELF } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { issueAccessToken } from '../src/auth/session.js';
import { SignJWT } from 'jose';

const SIGNING_KEY = 'test-session-signing-key-that-is-long-enough';

async function seedUser(): Promise<string> {
  const id = crypto.randomUUID();
  const now = Math.floor(Date.now() / 1_000);
  await env.DB.prepare(
    `INSERT INTO users (id, apple_sub, email, role, created_at, updated_at)
     VALUES (?1, ?2, NULL, 'user', ?3, ?3)`,
  )
    .bind(id, `apple-${id}`, now)
    .run();
  return id;
}

/** Access tokens are only honoured while their auth session row is live. */
async function seedAuthSession(userId: string): Promise<string> {
  const sessionId = crypto.randomUUID();
  const now = Math.floor(Date.now() / 1_000);
  await env.DB.prepare(
    `INSERT INTO auth_sessions
       (id, user_id, refresh_token_hash, device_label, created_at, expires_at)
     VALUES (?1, ?2, ?3, NULL, ?4, ?5)`,
  )
    .bind(sessionId, userId, sessionId.replace(/-/g, '').padEnd(64, '0'), now, now + 86_400)
    .run();
  return sessionId;
}

async function tokenFor(userId: string, role: 'user' | 'admin' = 'user'): Promise<string> {
  const now = Math.floor(Date.now() / 1_000);
  const issued = await issueAccessToken(
    SIGNING_KEY,
    { userId, sessionId: await seedAuthSession(userId), role },
    3_600,
    now,
  );
  return issued.token;
}

describe('authentication', () => {
  it('rejects a request with no Authorization header', async () => {
    const response = await SELF.fetch('https://api.test/v1/entitlement');
    expect(response.status).toBe(401);
    const body = (await response.json()) as { error: { code: string } };
    expect(body.error.code).toBe('unauthorized');
  });

  it('rejects a malformed Authorization header', async () => {
    const response = await SELF.fetch('https://api.test/v1/entitlement', {
      headers: { authorization: 'Basic abc123' },
    });
    expect(response.status).toBe(401);
  });

  it('rejects a token signed with the wrong key', async () => {
    const now = Math.floor(Date.now() / 1_000);
    const forged = await issueAccessToken(
      'a-completely-different-signing-key-32-chars',
      { userId: 'user-1', sessionId: 'session-1', role: 'user' },
      3_600,
      now,
    );
    const response = await SELF.fetch('https://api.test/v1/entitlement', {
      headers: { authorization: `Bearer ${forged.token}` },
    });
    expect(response.status).toBe(401);
  });

  it('rejects an expired token', async () => {
    const userId = await seedUser();
    const past = Math.floor(Date.now() / 1_000) - 7_200;
    const expired = await issueAccessToken(
      SIGNING_KEY,
      { userId, sessionId: crypto.randomUUID(), role: 'user' },
      60,
      past,
    );
    const response = await SELF.fetch('https://api.test/v1/entitlement', {
      headers: { authorization: `Bearer ${expired.token}` },
    });
    expect(response.status).toBe(401);
  });

  it('rejects an unsigned "alg: none" token', async () => {
    const header = btoa(JSON.stringify({ alg: 'none', typ: 'JWT' }))
      .replace(/=+$/, '')
      .replace(/\+/g, '-')
      .replace(/\//g, '_');
    const payload = btoa(
      JSON.stringify({ sub: 'user-1', sid: 's', role: 'user', exp: 9_999_999_999 }),
    )
      .replace(/=+$/, '')
      .replace(/\+/g, '-')
      .replace(/\//g, '_');
    const response = await SELF.fetch('https://api.test/v1/entitlement', {
      headers: { authorization: `Bearer ${header}.${payload}.` },
    });
    expect(response.status).toBe(401);
  });

  it('rejects a token whose issuer and audience do not match', async () => {
    const userId = await seedUser();
    const now = Math.floor(Date.now() / 1_000);
    const token = await new SignJWT({ sid: crypto.randomUUID(), role: 'user' })
      .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
      .setIssuer('https://evil.example/paid-access')
      .setAudience('justspeaktoit-app')
      .setSubject(userId)
      .setIssuedAt(now)
      .setExpirationTime(now + 3_600)
      .setJti(crypto.randomUUID())
      .sign(new TextEncoder().encode(SIGNING_KEY));

    const response = await SELF.fetch('https://api.test/v1/entitlement', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(response.status).toBe(401);
  });

  it('rejects a valid token for a user that does not exist', async () => {
    const issued = await issueAccessToken(
      SIGNING_KEY,
      { userId: crypto.randomUUID(), sessionId: crypto.randomUUID(), role: 'user' },
      3_600,
      Math.floor(Date.now() / 1_000),
    );
    const response = await SELF.fetch('https://api.test/v1/entitlement', {
      headers: { authorization: `Bearer ${issued.token}` },
    });
    expect(response.status).toBe(401);
  });

  it('rejects a valid token for a disabled account', async () => {
    const userId = await seedUser();
    await env.DB.prepare('UPDATE users SET disabled_at = ?2 WHERE id = ?1')
      .bind(userId, Math.floor(Date.now() / 1_000))
      .run();
    const response = await SELF.fetch('https://api.test/v1/entitlement', {
      headers: { authorization: `Bearer ${await tokenFor(userId)}` },
    });
    expect(response.status).toBe(401);
  });

  it('rejects a token whose role no longer matches the stored role', async () => {
    const userId = await seedUser();
    const response = await SELF.fetch('https://api.test/v1/entitlement', {
      headers: { authorization: `Bearer ${await tokenFor(userId, 'admin')}` },
    });
    expect(response.status).toBe(401);
  });

  it('rejects an access token whose auth session has been revoked', async () => {
    const userId = await seedUser();
    const token = await tokenFor(userId);
    const accepted = await SELF.fetch('https://api.test/v1/entitlement', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(accepted.status).toBe(200);

    await env.DB.prepare('UPDATE auth_sessions SET revoked_at = ?2 WHERE user_id = ?1')
      .bind(userId, Math.floor(Date.now() / 1_000))
      .run();

    const rejected = await SELF.fetch('https://api.test/v1/entitlement', {
      headers: { authorization: `Bearer ${token}` },
    });
    expect(rejected.status).toBe(401);
  });

  it('accepts a valid token and reports a fresh account as unentitled', async () => {
    const userId = await seedUser();
    const response = await SELF.fetch('https://api.test/v1/entitlement', {
      headers: { authorization: `Bearer ${await tokenFor(userId)}` },
    });
    expect(response.status).toBe(200);
    const body = (await response.json()) as {
      status: string;
      active: boolean;
      paid_routing_available: boolean;
      policy: { routes: unknown[] };
    };
    expect(body.status).toBe('none');
    expect(body.active).toBe(false);
    expect(body.paid_routing_available).toBe(false);
    expect(body.policy.routes).toHaveLength(3);
  });

  it('echoes a well-formed correlation id and generates one otherwise', async () => {
    const supplied = 'correlation-abc-123';
    const withId = await SELF.fetch('https://api.test/v1/health', {
      headers: { 'x-correlation-id': supplied },
    });
    expect(withId.headers.get('x-correlation-id')).toBe(supplied);

    const withoutId = await SELF.fetch('https://api.test/v1/health');
    const generated = withoutId.headers.get('x-correlation-id');
    expect(generated).toBeTruthy();
    expect(generated).not.toBe(supplied);
  });

  it('rejects an injected correlation id that is not URL-safe', async () => {
    const response = await SELF.fetch('https://api.test/v1/health', {
      headers: { 'x-correlation-id': 'bad id with spaces and "quotes"' },
    });
    expect(response.headers.get('x-correlation-id')).not.toContain(' ');
  });

  it('rejects an unverifiable Apple identity token without creating a user', async () => {
    const before = await env.DB.prepare('SELECT COUNT(*) AS total FROM users').first<{
      total: number;
    }>();
    const response = await SELF.fetch('https://api.test/v1/auth/apple', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({
        identity_token: 'aaa.bbb.ccc',
        nonce: 'a-nonce-that-is-long-enough',
      }),
    });
    expect(response.status).toBe(401);
    const after = await env.DB.prepare('SELECT COUNT(*) AS total FROM users').first<{
      total: number;
    }>();
    expect(after?.total).toBe(before?.total);
  });

  it('requires a nonce on Apple sign-in', async () => {
    const response = await SELF.fetch('https://api.test/v1/auth/apple', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ identity_token: 'aaa.bbb.ccc' }),
    });
    expect(response.status).toBe(400);
  });

  it('rejects an unknown refresh token', async () => {
    const response = await SELF.fetch('https://api.test/v1/auth/refresh', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify({ refresh_token: 'not-a-real-token' }),
    });
    expect(response.status).toBe(401);
  });

  it('exposes no delete endpoints', async () => {
    for (const path of ['/v1/entitlement', '/v1/paid/post-process', '/v1/auth/apple']) {
      const response = await SELF.fetch(`https://api.test${path}`, { method: 'DELETE' });
      expect(response.status).toBe(404);
    }
  });
});
