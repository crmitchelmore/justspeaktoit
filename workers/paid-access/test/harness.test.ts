import { env, runInDurableObject } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { installUpstreamMock, mockOpenRouterResponse, verifyUpstreamMock } from './upstream.js';

describe('worker test isolation', () => {
  it('handles a nested async rejection without reporting an unhandled error', async () => {
    const failure = (): Promise<never> => Promise.reject(new Error('handled test rejection'));
    await expect(Promise.resolve().then(failure)).rejects.toThrow('handled test rejection');
  });

  it.each([1, 2])('starts case %s with empty D1 and Durable Object storage', async () => {
    expect(await env.DB.prepare('SELECT COUNT(*) AS total FROM users').first('total')).toBe(0);
    const stub = env.QUOTA.get(env.QUOTA.idFromName('harness-storage-reset'));
    await runInDurableObject(stub, async (_instance, state) => {
      expect(await state.storage.get('harness-marker')).toBeUndefined();
      expect(await state.storage.getAlarm()).toBeNull();
      await state.storage.put('harness-marker', true);
      await state.storage.setAlarm(Date.now() + 60_000);
    });
    await env.DB.prepare(`INSERT INTO users (id, apple_sub, role, created_at, updated_at)
      VALUES ('harness-user', 'harness-apple', 'user', 1, 1)`).run();
  });
});

describe('one-shot upstream responses', () => {
  it('returns the registered response without using the real network', async () => {
    mockOpenRouterResponse({ choices: [] });
    const response = await fetch('https://openrouter.ai/api/v1/chat/completions', { method: 'POST' });
    expect(await response.json()).toEqual({ choices: [] });
  });

  it('detects an unused response', () => {
    mockOpenRouterResponse({ choices: [] });
    expect(verifyUpstreamMock).toThrow();
    installUpstreamMock();
  });

  it('rejects and detects unmatched and repeated requests', async () => {
    mockOpenRouterResponse({ choices: [] });
    await fetch('https://openrouter.ai/api/v1/chat/completions', { method: 'POST' });
    expect(() => fetch('https://openrouter.ai/api/v1/chat/completions', { method: 'POST' })).toThrow();
    expect(() => fetch('https://unexpected.test/')).toThrow();
    expect(verifyUpstreamMock).toThrow();
    installUpstreamMock();
  });
});
