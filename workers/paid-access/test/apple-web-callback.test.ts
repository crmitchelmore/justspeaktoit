import { SELF } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';

const STATE = 'abcdefghijklmnop_QRSTUV-123';
const TOKEN = 'eyJhbGciOiJSUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl';

function post(fields: Record<string, string>, contentType = 'application/x-www-form-urlencoded') {
  return SELF.fetch('https://api.test/v1/auth/apple/callback', {
    method: 'POST',
    headers: { 'content-type': contentType },
    body: new URLSearchParams(fields).toString(),
    redirect: 'manual',
  });
}

function relayed(response: Response): URL {
  expect(response.status).toBe(303);
  expect(response.headers.get('cache-control')).toBe('no-store');
  const location = new URL(response.headers.get('location') ?? '');
  expect(`${location.protocol}//${location.host}`).toBe('justspeaktoit-auth://apple-callback');
  return location;
}

describe('Sign in with Apple web callback', () => {
  it('relays the identity token and state to the app without creating a session', async () => {
    const location = relayed(await post({ state: STATE, id_token: TOKEN, code: 'unused' }));
    expect(location.searchParams.get('state')).toBe(STATE);
    expect(location.searchParams.get('id_token')).toBe(TOKEN);
    expect(location.searchParams.has('code')).toBe(false);
  });

  it('reports cancellation and failures to the app', async () => {
    const cancelled = relayed(await post({ state: STATE, error: 'user_cancelled_authorize' }));
    expect(cancelled.searchParams.get('error')).toBe('cancelled');
    const failed = relayed(await post({ state: STATE, error: 'invalid_request' }));
    expect(failed.searchParams.get('error')).toBe('failed');
    const malformed = relayed(await post({ state: STATE, id_token: 'not-a-jwt' }));
    expect(malformed.searchParams.get('error')).toBe('failed');
    expect(malformed.searchParams.has('id_token')).toBe(false);
  });

  it('refuses a missing state or a non-form body', async () => {
    expect((await post({ id_token: TOKEN })).status).toBe(400);
    expect((await post({ state: 'short', id_token: TOKEN })).status).toBe(400);
    expect((await post({ state: STATE, id_token: TOKEN }, 'application/json')).status).toBe(400);
  });

  it('accepts only POST', async () => {
    const response = await SELF.fetch(`https://api.test/v1/auth/apple/callback?state=${STATE}&id_token=${TOKEN}`);
    expect(response.status).toBe(404);
  });
});
