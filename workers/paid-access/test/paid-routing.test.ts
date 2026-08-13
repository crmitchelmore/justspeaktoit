import { env, fetchMock, SELF } from 'cloudflare:test';
import { afterEach, beforeAll, describe, expect, it } from 'vitest';
import { issueAccessToken } from '../src/auth/session.js';

const SIGNING_KEY = 'test-session-signing-key-that-is-long-enough';
const IDEMPOTENCY_KEY = 'client-request-key-0000000001';

beforeAll(() => {
  fetchMock.activate();
  fetchMock.disableNetConnect();
});

afterEach(() => fetchMock.assertNoPendingInterceptors());

async function seedEntitledUser(status = 'active'): Promise<string> {
  const userId = crypto.randomUUID();
  const now = Math.floor(Date.now() / 1_000);
  await env.DB.prepare(
    `INSERT INTO users (id, apple_sub, role, created_at, updated_at)
     VALUES (?1, ?2, 'user', ?3, ?3)`,
  )
    .bind(userId, `apple-${userId}`, now)
    .run();
  await env.DB.prepare(
    `INSERT INTO entitlements
       (id, user_id, plan_id, status, source, source_reference,
        current_period_start, current_period_end, created_at, updated_at)
     VALUES (?1, ?2, 'paid', ?3, 'stripe', ?4, ?5, ?6, ?5, ?5)`,
  )
    .bind(crypto.randomUUID(), userId, status, `sub_${userId}`, now, now + 86_400)
    .run();
  return userId;
}

async function seedUnentitledUser(): Promise<string> {
  const userId = crypto.randomUUID();
  const now = Math.floor(Date.now() / 1_000);
  await env.DB.prepare(
    `INSERT INTO users (id, apple_sub, role, created_at, updated_at)
     VALUES (?1, ?2, 'user', ?3, ?3)`,
  )
    .bind(userId, `apple-${userId}`, now)
    .run();
  return userId;
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

async function tokenFor(userId: string): Promise<string> {
  const issued = await issueAccessToken(
    SIGNING_KEY,
    { userId, sessionId: await seedAuthSession(userId), role: 'user' },
    3_600,
    Math.floor(Date.now() / 1_000),
  );
  return issued.token;
}

function mockOpenRouterCompletion(text: string): void {
  fetchMock
    .get('https://openrouter.ai')
    .intercept({ path: '/api/v1/chat/completions', method: 'POST' })
    .reply(200, {
      choices: [{ message: { content: text } }],
      usage: { prompt_tokens: 40, completion_tokens: 20 },
    });
}

async function postProcess(
  token: string,
  body: Record<string, unknown>,
  headers: Record<string, string> = {},
): Promise<Response> {
  return SELF.fetch('https://api.test/v1/paid/post-process', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'application/json',
      'idempotency-key': IDEMPOTENCY_KEY,
      ...headers,
    },
    body: JSON.stringify(body),
  });
}

/** A minimal but genuine 16-bit PCM WAV, so the duration is read not guessed. */
function wavPayload(input: { seconds: number; sampleRate: number; channels: number }): Uint8Array {
  const blockAlign = input.channels * 2;
  const byteRate = input.sampleRate * blockAlign;
  const dataBytes = byteRate * input.seconds;
  const buffer = new ArrayBuffer(44 + dataBytes);
  const view = new DataView(buffer);
  const ascii = (offset: number, text: string): void => {
    for (let index = 0; index < text.length; index += 1) {
      view.setUint8(offset + index, text.charCodeAt(index));
    }
  };
  ascii(0, 'RIFF');
  view.setUint32(4, 36 + dataBytes, true);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, input.channels, true);
  view.setUint32(24, input.sampleRate, true);
  view.setUint32(28, byteRate, true);
  view.setUint16(32, blockAlign, true);
  view.setUint16(34, 16, true);
  ascii(36, 'data');
  view.setUint32(40, dataBytes, true);
  return new Uint8Array(buffer);
}

async function transcribeBatch(token: string, audio: Uint8Array): Promise<Response> {
  return SELF.fetch('https://api.test/v1/paid/transcribe/batch', {
    method: 'POST',
    headers: {
      authorization: `Bearer ${token}`,
      'content-type': 'audio/wav',
      'idempotency-key': IDEMPOTENCY_KEY,
    },
    body: audio,
  });
}

describe('paid routing entitlement gate', () => {
  it('refuses an unentitled account with 402 and records the denial', async () => {
    const userId = await seedUnentitledUser();
    const response = await postProcess(await tokenFor(userId), {
      operation: 'post_processing',
      text: 'hello world',
    });

    expect(response.status).toBe(402);
    const body = (await response.json()) as { error: { code: string } };
    expect(body.error.code).toBe('entitlement_required');

    const audit = await env.DB.prepare(
      `SELECT outcome FROM audit_events WHERE user_id = ?1 AND action = 'paid.access_check'`,
    )
      .bind(userId)
      .first<{ outcome: string }>();
    expect(audit?.outcome).toBe('denied');
  });

  it('refuses an account whose subscription has lapsed', async () => {
    const userId = await seedEntitledUser('active');
    const lapsedEnd = Math.floor(Date.now() / 1_000) - 10;
    await env.DB.prepare(
      'UPDATE entitlements SET current_period_start = ?2, current_period_end = ?3 WHERE user_id = ?1',
    )
      .bind(userId, lapsedEnd - 86_400, lapsedEnd)
      .run();

    const response = await postProcess(await tokenFor(userId), {
      operation: 'post_processing',
      text: 'hello world',
    });
    expect(response.status).toBe(402);
  });

  it('refuses a revoked account even inside a paid period', async () => {
    const userId = await seedEntitledUser('active');
    const now = Math.floor(Date.now() / 1_000);
    await env.DB.prepare(
      `UPDATE entitlements SET status = 'revoked', revoked_at = ?2 WHERE user_id = ?1`,
    )
      .bind(userId, now)
      .run();

    const response = await postProcess(await tokenFor(userId), {
      operation: 'post_processing',
      text: 'hello world',
    });
    expect(response.status).toBe(402);
  });

  it('refuses a past_due account', async () => {
    const userId = await seedEntitledUser('past_due');
    const response = await postProcess(await tokenFor(userId), {
      operation: 'post_processing',
      text: 'hello world',
    });
    expect(response.status).toBe(402);
  });

  it('serves an entitled account and records metered usage', async () => {
    const userId = await seedEntitledUser();
    mockOpenRouterCompletion('Hello, world.');

    const response = await postProcess(await tokenFor(userId), {
      operation: 'post_processing',
      text: 'hello world',
    });

    expect(response.status).toBe(200);
    const body = (await response.json()) as { text: string; model: string; provider: string };
    expect(body.text).toBe('Hello, world.');
    // The server, not the client, decided which model was used.
    expect(body.model).toBe('openai/gpt-5-mini');
    expect(body.provider).toBe('openrouter');

    const usage = await env.DB.prepare(
      `SELECT operation, model, unit_kind, units FROM usage_ledger WHERE user_id = ?1`,
    )
      .bind(userId)
      .first<{ operation: string; model: string; unit_kind: string; units: number }>();
    expect(usage?.operation).toBe('post_processing');
    expect(usage?.model).toBe('openai/gpt-5-mini');
    expect(usage?.unit_kind).toBe('tokens');
    // 40 prompt + 20 completion tokens, as reported by the provider.
    expect(usage?.units).toBe(60);
  });

  it('grants access during a grace period', async () => {
    const userId = await seedEntitledUser('grace');
    mockOpenRouterCompletion('Cleaned up.');
    const response = await postProcess(await tokenFor(userId), {
      operation: 'post_processing',
      text: 'hello world',
    });
    expect(response.status).toBe(200);
  });
});

describe('paid routing request validation', () => {
  it('requires an idempotency key', async () => {
    const userId = await seedEntitledUser();
    const response = await SELF.fetch('https://api.test/v1/paid/post-process', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${await tokenFor(userId)}`,
        'content-type': 'application/json',
      },
      body: JSON.stringify({ operation: 'post_processing', text: 'hello' }),
    });
    expect(response.status).toBe(400);
  });

  it('rejects a malformed idempotency key', async () => {
    const userId = await seedEntitledUser();
    const response = await postProcess(
      await tokenFor(userId),
      { operation: 'post_processing', text: 'hello' },
      { 'idempotency-key': 'short' },
    );
    expect(response.status).toBe(400);
  });

  it('rejects an operation the paid surface does not support', async () => {
    const userId = await seedEntitledUser();
    const response = await postProcess(await tokenFor(userId), {
      operation: 'translation',
      text: 'hello',
    });
    expect(response.status).toBe(400);
  });

  it('ignores any model the client tries to name', async () => {
    const userId = await seedEntitledUser();
    mockOpenRouterCompletion('Server chose the model.');

    const response = await postProcess(await tokenFor(userId), {
      operation: 'post_processing',
      text: 'hello world',
      model: 'anthropic/claude-opus-4',
      provider: 'anthropic',
      cost: 0,
    });

    expect(response.status).toBe(200);
    const body = (await response.json()) as { model: string; provider: string };
    expect(body.model).toBe('openai/gpt-5-mini');
    expect(body.provider).toBe('openrouter');
  });

  it('rejects text that exceeds the maximum length', async () => {
    const userId = await seedEntitledUser();
    const response = await postProcess(await tokenFor(userId), {
      operation: 'post_processing',
      text: 'x'.repeat(100_001),
    });
    expect([400, 413]).toContain(response.status);
  });

  it('rejects an oversized request body outright', async () => {
    const userId = await seedEntitledUser();
    const response = await postProcess(await tokenFor(userId), {
      operation: 'post_processing',
      text: 'x'.repeat(400_000),
    });
    expect(response.status).toBe(413);
  });

  it('rejects batch transcription with a non-audio content type', async () => {
    const userId = await seedEntitledUser();
    const response = await SELF.fetch('https://api.test/v1/paid/transcribe/batch', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${await tokenFor(userId)}`,
        'content-type': 'application/json',
        'idempotency-key': IDEMPOTENCY_KEY,
      },
      body: '{}',
    });
    expect(response.status).toBe(400);
  });

  it('rejects a live transcription request that is not a WebSocket upgrade', async () => {
    const userId = await seedEntitledUser();
    const response = await SELF.fetch('https://api.test/v1/paid/transcribe/live', {
      headers: { authorization: `Bearer ${await tokenFor(userId)}` },
    });
    expect(response.status).toBe(400);
  });

  it('rejects a finalise call for a session that never existed', async () => {
    const userId = await seedEntitledUser();
    const response = await SELF.fetch(
      'https://api.test/v1/paid/transcribe/live/finalise',
      {
        method: 'POST',
        headers: {
          authorization: `Bearer ${await tokenFor(userId)}`,
          'content-type': 'application/json',
          'idempotency-key': IDEMPOTENCY_KEY,
        },
        body: JSON.stringify({ session_id: 'never-opened' }),
      },
    );
    expect(response.status).toBe(404);

    const usage = await env.DB.prepare(
      'SELECT COUNT(*) AS total FROM usage_ledger WHERE user_id = ?1',
    )
      .bind(userId)
      .first<{ total: number }>();
    expect(usage?.total).toBe(0);
  });

  it('rejects an unsupported sample rate on live transcription', async () => {
    const userId = await seedEntitledUser();
    const response = await SELF.fetch(
      'https://api.test/v1/paid/transcribe/live?sample_rate=12345',
      {
        headers: {
          authorization: `Bearer ${await tokenFor(userId)}`,
          upgrade: 'websocket',
        },
      },
    );
    expect(response.status).toBe(400);
  });
});

describe('paid routing usage accounting', () => {
  it('refuses a retried request instead of calling the provider again', async () => {
    const userId = await seedEntitledUser();
    const token = await tokenFor(userId);

    // Exactly one interceptor is registered. If the retry reached OpenRouter the
    // request would fail outright, which is the guarantee being tested: the key
    // is claimed before the vendor is called, so a client that lost the first
    // response to a timeout cannot be charged for a second one.
    mockOpenRouterCompletion('First.');
    const first = await postProcess(token, { operation: 'post_processing', text: 'a' });
    expect(first.status).toBe(200);
    expect(((await first.json()) as { text: string }).text).toBe('First.');

    // The response is deliberately not replayed. Storing it would make the
    // claims table a store of dictated text, which the service promises never
    // to retain, so the retry is told the work already happened instead.
    const retry = await postProcess(token, { operation: 'post_processing', text: 'a' });
    expect(retry.status).toBe(409);
    const body = (await retry.json()) as { error: { code: string } };
    expect(body.error.code).toBe('already_processed');

    const row = await env.DB.prepare(
      'SELECT COUNT(*) AS total FROM usage_ledger WHERE user_id = ?1',
    )
      .bind(userId)
      .first<{ total: number }>();
    expect(row?.total).toBe(1);
  });

  it('processes identical text sent under a new key as a new request', async () => {
    // Dictating the same words twice is ordinary use, not a duplicate. The key
    // identifies one attempt, so the second dictation carries its own and must
    // be served and billed in its own right.
    const userId = await seedEntitledUser();
    const token = await tokenFor(userId);

    mockOpenRouterCompletion('First.');
    const first = await postProcess(token, { operation: 'post_processing', text: 'a' });
    expect(first.status).toBe(200);

    mockOpenRouterCompletion('Second.');
    const second = await postProcess(
      token,
      { operation: 'post_processing', text: 'a' },
      { 'idempotency-key': `${IDEMPOTENCY_KEY}-second-attempt` },
    );
    expect(second.status).toBe(200);
    expect(((await second.json()) as { text: string }).text).toBe('Second.');

    const row = await env.DB.prepare(
      'SELECT COUNT(*) AS total FROM usage_ledger WHERE user_id = ?1',
    )
      .bind(userId)
      .first<{ total: number }>();
    expect(row?.total).toBe(2);
  });

  it('stores no request or response content alongside a claim', async () => {
    const userId = await seedEntitledUser();
    mockOpenRouterCompletion('Sensitive dictated text.');
    await postProcess(await tokenFor(userId), {
      operation: 'post_processing',
      text: 'Sensitive dictated text.',
    });

    // Whatever columns the claims table grows, none of them may hold content.
    const claim = await env.DB.prepare('SELECT * FROM request_claims WHERE user_id = ?1')
      .bind(userId)
      .first<Record<string, unknown>>();
    expect(claim).not.toBeNull();
    for (const value of Object.values(claim ?? {})) {
      if (typeof value !== 'string') continue;
      expect(value).not.toContain('Sensitive');
      expect(value).not.toContain('dictated');
    }
  });

  it('meters batch transcription by the duration in the WAV header, not the byte count', async () => {
    const userId = await seedEntitledUser();
    mockOpenRouterCompletion('Transcribed.');

    // Three seconds at 48 kHz stereo 16-bit: 576 kB of audio that a fixed
    // 32 kB-per-second estimate would have billed as eighteen seconds.
    const response = await transcribeBatch(
      await tokenFor(userId),
      wavPayload({ seconds: 3, sampleRate: 48_000, channels: 2 }),
    );
    expect(response.status).toBe(200);

    const usage = await env.DB.prepare(
      `SELECT unit_kind, units FROM usage_ledger WHERE user_id = ?1`,
    )
      .bind(userId)
      .first<{ unit_kind: string; units: number }>();
    expect(usage?.unit_kind).toBe('audio_seconds');
    expect(usage?.units).toBe(3);
  });

  it('rejects audio it cannot measure rather than guessing at the duration', async () => {
    const userId = await seedEntitledUser();
    const response = await SELF.fetch('https://api.test/v1/paid/transcribe/batch', {
      method: 'POST',
      headers: {
        authorization: `Bearer ${await tokenFor(userId)}`,
        'content-type': 'audio/mp4',
        'idempotency-key': IDEMPOTENCY_KEY,
      },
      body: new Uint8Array(64_000),
    });
    expect(response.status).toBe(400);

    const usage = await env.DB.prepare(
      'SELECT COUNT(*) AS total FROM usage_ledger WHERE user_id = ?1',
    )
      .bind(userId)
      .first<{ total: number }>();
    expect(usage?.total).toBe(0);
  });

  it('releases the reservation when the provider fails', async () => {
    const userId = await seedEntitledUser();
    fetchMock
      .get('https://openrouter.ai')
      .intercept({ path: '/api/v1/chat/completions', method: 'POST' })
      .reply(500, 'upstream exploded');

    const response = await postProcess(await tokenFor(userId), {
      operation: 'post_processing',
      text: 'hello world',
    });
    expect(response.status).toBe(502);

    // No usage is recorded for a failed call, and the reservation is returned.
    const usage = await env.DB.prepare(
      'SELECT COUNT(*) AS total FROM usage_ledger WHERE user_id = ?1',
    )
      .bind(userId)
      .first<{ total: number }>();
    expect(usage?.total).toBe(0);

    const entitlement = await SELF.fetch('https://api.test/v1/entitlement', {
      headers: { authorization: `Bearer ${await tokenFor(userId)}` },
    });
    const body = (await entitlement.json()) as { usage: { tokens_used: number } };
    expect(body.usage.tokens_used).toBe(0);
  });

  it('reports paid routing as available for an entitled account', async () => {
    const userId = await seedEntitledUser();
    const response = await SELF.fetch('https://api.test/v1/entitlement', {
      headers: { authorization: `Bearer ${await tokenFor(userId)}` },
    });
    const body = (await response.json()) as {
      active: boolean;
      paid_routing_available: boolean;
      policy: { routes: { operation: string; model: string }[] };
    };
    expect(body.active).toBe(true);
    expect(body.paid_routing_available).toBe(true);
    expect(body.policy.routes.map((route) => route.operation).sort()).toEqual([
      'batch_transcription',
      'live_transcription',
      'post_processing',
    ]);
  });
});
