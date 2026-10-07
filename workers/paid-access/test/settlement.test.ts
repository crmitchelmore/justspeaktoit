import { env, fetchMock, runDurableObjectAlarm, runInDurableObject } from 'cloudflare:test';
import { afterEach, beforeAll, describe, expect, it, vi } from 'vitest';
import worker from '../src/index.js';
import { issueAccessToken } from '../src/auth/session.js';
import { Repository } from '../src/data/repository.js';
import { QuotaClient } from '../src/quota.js';
import { QuotaDurableObject } from '../src/do/quota.js';
import { pendingKey, receiptKey, type SettlementReceipt, type SettlementRequest,
  type SettlementResponse } from '../src/do/settlement.js';

const KEY = 'settlement-operation-0001';
const TEXT = 'Synthetic request, never persisted.';
const LIMITS = { monthlyAudioSeconds: 100, monthlyTokens: 100_000, maxConcurrentSessions: 2, leaseSeconds: 60 };
const now = (): number => Math.floor(Date.now() / 1000);
beforeAll(() => { fetchMock.activate(); fetchMock.disableNetConnect(); });
afterEach(async () => {
  vi.restoreAllMocks();
  await env.DB.prepare('DROP TRIGGER IF EXISTS settlement_fail_ledger').run();
  fetchMock.assertNoPendingInterceptors();
});

async function account(): Promise<{ userId: string; token: string }> {
  const userId = crypto.randomUUID(); const sessionId = crypto.randomUUID(); const time = now();
  await env.DB.prepare(`INSERT INTO users (id,apple_sub,role,created_at,updated_at)
    VALUES (?1,?1,'user',?2,?2)`).bind(userId, time).run();
  await env.DB.prepare(`INSERT INTO auth_sessions (id,user_id,refresh_token_hash,created_at,expires_at)
    VALUES (?1,?2,?3,?4,?5)`).bind(sessionId, userId, sessionId.replace(/-/g, '').padEnd(64, '0'), time, time + 86400).run();
  await env.DB.prepare(`INSERT INTO entitlements
    (id,user_id,plan_id,status,source,source_reference,current_period_start,current_period_end,created_at,updated_at)
    VALUES (?1,?1,'paid','active','stripe',?1,?2,?3,?2,?2)`).bind(userId, time, time + 86400).run();
  const issued = await issueAccessToken('test-session-signing-key-that-is-long-enough',
    { userId, sessionId, role: 'user' }, 3600, time);
  return { userId, token: issued.token };
}

function request(token: string, key = KEY, version: string | null = '1'): Request {
  const headers: Record<string, string> = { authorization: `Bearer ${token}`,
    'content-type': 'application/json', 'idempotency-key': key };
  if (version !== null) headers['x-paid-settlement-contract'] = version;
  return new Request('https://api.test/v1/paid/post-process', { method: 'POST', headers,
    body: JSON.stringify({ operation: 'post_processing', text: TEXT }) });
}
function provider(usage: unknown = { prompt_tokens: 40, completion_tokens: 20 }): { calls: number } {
  const count = { calls: 0 };
  fetchMock.get('https://openrouter.ai').intercept({ path: '/api/v1/chat/completions', method: 'POST' })
    .reply(() => { count.calls += 1; return { statusCode: 200,
      data: JSON.stringify({ choices: [{ message: { content: 'Synthetic result.' } }], usage }) }; });
  return count;
}
function stub(user: string): DurableObjectStub { return env.QUOTA.get(env.QUOTA.idFromName(`user:${user}`)); }
async function receipt(user: string, key = KEY): Promise<SettlementReceipt | undefined> {
  return runInDurableObject(stub(user), async (_instance, state) => state.storage.get(receiptKey(key)));
}
/** Each call constructs production code anew against actual durable storage. */
async function operation(user: string, input: SettlementRequest): Promise<SettlementResponse> {
  return runInDurableObject(stub(user), async (_instance, state) => {
    const fresh = new QuotaDurableObject(state, env);
    const response = await fresh.fetch(new Request('https://quota.invalid', {
      method: 'POST', body: JSON.stringify(input),
    }));
    return response.json<SettlementResponse>();
  });
}
async function reserve(userId: string, key = KEY, units = 100, period = '2026-10'): Promise<SettlementReceipt> {
  const result = await operation(userId, { kind: 'operation_reserve', userId, idempotencyKey: key,
    operation: 'post_processing', ownerId: crypto.randomUUID(), provider: 'openrouter', model: 'openai/gpt-5-mini',
    unitKind: 'tokens', period, units, correlationId: 'synthetic-correlation', nowSeconds: now(), limits: LIMITS });
  expect(result.ok).toBe(true); return result.receipt!;
}
async function start(user: string, item: SettlementReceipt): Promise<SettlementReceipt> {
  const result = await operation(user, { kind: 'operation_start', idempotencyKey: item.idempotencyKey,
    ownerId: item.ownerId, revision: item.revision, nowSeconds: now() });
  expect(result.ok).toBe(true); return result.receipt!;
}
async function measure(user: string, item: SettlementReceipt, units = 60): Promise<SettlementReceipt> {
  const result = await operation(user, { kind: 'operation_measure', idempotencyKey: item.idempotencyKey,
    ownerId: item.ownerId, revision: item.revision, nowSeconds: now(), actualUnits: units, measuredAt: now() });
  expect(result.ok).toBe(true); return result.receipt!;
}
async function ledger(user: string): Promise<Record<string, unknown>[]> {
  return (await env.DB.prepare('SELECT * FROM usage_ledger WHERE user_id=?1').bind(user).all()).results;
}
async function snapshot(user: string, period = '2026-10') {
  return new QuotaClient(env.QUOTA, LIMITS).status(user, period, now());
}
async function rejectLedger(): Promise<void> {
  await env.DB.prepare(`CREATE TRIGGER settlement_fail_ledger BEFORE INSERT ON usage_ledger
    BEGIN SELECT RAISE(ABORT, 'synthetic-ledger-failure'); END`).run();
}
async function alarm(user: string): Promise<void> {
  await runInDurableObject(stub(user), async (_instance, state) => {
    // Make only the existing metadata retry due; no synthetic quota/ledger result.
    const receipts = await state.storage.list<SettlementReceipt>({ prefix: 'operation:' });
    for (const item of receipts.values()) {
      if (item.phase !== 'ledger_pending' || item.nextReconcileAt === undefined) continue;
      await state.storage.delete(pendingKey(item));
      item.nextReconcileAt = now() - 1;
      await state.storage.put({ [receiptKey(item.idempotencyKey)]: item,
        [pendingKey(item)]: item.idempotencyKey });
    }
    await new QuotaDurableObject(state, env).alarm();
  });
}

const observations: unknown[] = [];
async function observe(user: string, response: Response, count: number): Promise<void> {
  const state = await runInDurableObject(stub(user), async (_instance, storage) =>
    Object.fromEntries(await storage.storage.list()));
  const claims = await env.DB.prepare('SELECT operation,status FROM request_claims WHERE user_id=?1').bind(user).all();
  observations.push({ response: response.status, providerCalls: count, ledger: await ledger(user),
    claims: claims.results, quota: state });
  console.log('SETTLEMENT_AFTER', JSON.stringify(observations.at(-1)));
  expect(JSON.stringify(state)).not.toContain(TEXT);
  expect(JSON.stringify(state)).not.toContain('Synthetic result.');
  const receiptFields = new Set(['schemaVersion', 'userId', 'idempotencyKey', 'operation', 'reservationId',
    'ledgerEntryId', 'ownerId', 'provider', 'model', 'unitKind', 'billingPeriod', 'reservedUnits', 'phase',
    'revision', 'createdAt', 'updatedAt', 'expiresAt', 'correlationId', 'actualUnits', 'measuredAt',
    'nextReconcileAt', 'reconcileAttempts', 'lastFailure']);
  for (const [key, value] of Object.entries(state)) {
    if (key.startsWith('operation:')) {
      expect(Object.keys(value as Record<string, unknown>).filter(field => !receiptFields.has(field))).toEqual([]);
    }
  }
}

describe('actual routed settlement faults', () => {
  it('retains measured quota/receipt when the actual D1 ledger rejects writes, then reconciles once', async () => {
    const a = await account(); const count = provider(); await rejectLedger();
    const first = await worker.fetch(request(a.token), env);
    expect(first.status).toBe(200); expect(await first.json()).toMatchObject({ text: 'Synthetic result.' });
    expect((await receipt(a.userId))?.phase).toBe('ledger_pending');
    expect((await snapshot(a.userId)).tokensUsed).toBe(60); expect(await ledger(a.userId)).toHaveLength(0);
    await observe(a.userId, first, count.calls);
    await env.DB.prepare('DELETE FROM request_claims WHERE user_id=?1').bind(a.userId).run();
    const retry = await worker.fetch(request(a.token), env);
    expect(await retry.json()).toMatchObject({ error: { code: 'settlement_pending' } });
    await env.DB.prepare('DROP TRIGGER settlement_fail_ledger').run(); await alarm(a.userId);
    expect((await receipt(a.userId))?.phase).toBe('settled');
    expect(await ledger(a.userId)).toHaveLength(1); expect((await ledger(a.userId))[0]?.units).toBe(60);
    expect(count.calls).toBe(1); expect((await snapshot(a.userId)).tokensUsed).toBe(60);
    await observe(a.userId, retry, count.calls);
  });

  it.each(['operation_measure', 'operation_reconcile'] as const)('survives committed %s with its acknowledgement lost', async kind => {
    const a = await account(); const count = provider();
    // The captured original is invoked with the real receiver through .call below.
    // eslint-disable-next-line @typescript-eslint/unbound-method
    const original = QuotaClient.prototype.operation;
    let injected = false;
    vi.spyOn(QuotaClient.prototype, 'operation').mockImplementation(async function(this: QuotaClient, user, input) {
      const result = await original.call(this, user, input);
      if (input.kind === kind && !injected) { injected = true; throw new Error('synthetic-lost-ack'); }
      return result;
    });
    const first = await worker.fetch(request(a.token), env); expect(first.status).toBe(200); expect(injected).toBe(true);
    const retry = await worker.fetch(request(a.token), env); expect(retry.status).toBe(409);
    expect(count.calls).toBe(1); expect((await snapshot(a.userId)).tokensUsed).toBe(60);
    expect(await ledger(a.userId)).toHaveLength(1); await observe(a.userId, retry, count.calls);
  });

  it('reconciles actual routed success after D1 commits but its acknowledgement throws', async () => {
    const a = await account(); const count = provider();
    // Bindings normally execute the same DO source in their own context. This wrapper invokes
    // that source anew against its actual durable storage so the D1 acknowledgement can be lost.
    // eslint-disable-next-line @typescript-eslint/unbound-method -- .call preserves the actual receiver.
    const rpc = QuotaClient.prototype.operation;
    vi.spyOn(QuotaClient.prototype, 'operation').mockImplementation(function(this: QuotaClient, user, input) {
      return input.kind === 'operation_reconcile' ? operation(user, input) : rpc.call(this, user, input);
    });
    // eslint-disable-next-line @typescript-eslint/unbound-method -- .call preserves the actual repository receiver.
    const insert = Repository.prototype.reconcileUsage;
    let injected = false;
    vi.spyOn(Repository.prototype, 'reconcileUsage').mockImplementationOnce(async function(this: Repository, input) {
      await insert.call(this, input); injected = true; throw new Error('synthetic-committed-ledger-ack-lost');
    });
    const first = await worker.fetch(request(a.token), env);
    expect(first.status).toBe(200); expect(injected).toBe(true);
    expect(await ledger(a.userId)).toHaveLength(1); expect((await receipt(a.userId))?.phase).toBe('ledger_pending');
    await observe(a.userId, first, count.calls);
    const retry = await worker.fetch(request(a.token), env); expect(retry.status).toBe(409);
    await alarm(a.userId); expect((await receipt(a.userId))?.phase).toBe('settled');
    expect(await ledger(a.userId)).toHaveLength(1); expect((await snapshot(a.userId)).tokensUsed).toBe(60);
    expect(count.calls).toBe(1); await observe(a.userId, retry, count.calls);
  });

  it.each(['operation_reserve', 'operation_start'] as const)('never dispatches after a lost %s acknowledgement', async kind => {
    const a = await account();
    // eslint-disable-next-line @typescript-eslint/unbound-method -- .call preserves the actual quota client receiver.
    const original = QuotaClient.prototype.operation; let injected = false;
    vi.spyOn(QuotaClient.prototype, 'operation').mockImplementation(async function(this: QuotaClient, user, input) {
      const result = await original.call(this, user, input);
      if (input.kind === kind && !injected) { injected = true; throw new Error('synthetic-lost-permit'); }
      return result;
    });
    expect((await worker.fetch(request(a.token), env)).status).toBe(409); expect(injected).toBe(true);
    expect((await worker.fetch(request(a.token), env)).status).toBe(409);
    expect(await ledger(a.userId)).toHaveLength(0); // Any provider call fails unmatched network denial.
    expect((await receipt(a.userId))?.phase).toBe(kind === 'operation_reserve' ? 'reserved' : 'outcome_unknown');
  });

  it.each([undefined, {}, { prompt_tokens: 1 }, { prompt_tokens: -1, completion_tokens: 2 },
    { prompt_tokens: 1.5, completion_tokens: 2 }, { prompt_tokens: Number.MAX_SAFE_INTEGER, completion_tokens: 2 }])(
    'retains an unknown hold for absent/invalid measurement %j', async usage => {
      const a = await account(); const count = provider(usage ?? null);
      const result = await worker.fetch(request(a.token), env);
      expect(await result.json()).toMatchObject({ error: { code: 'outcome_unknown' } });
      const state = await snapshot(a.userId); expect(state.tokensMeasured).toBe(0);
      expect(state.tokensHeld).toBeGreaterThan(0); expect(state.tokensUsed).toBe(state.tokensHeld);
      expect(await ledger(a.userId)).toHaveLength(0); expect(count.calls).toBe(1);
      expect((await worker.fetch(request(a.token), env)).status).toBe(409);
    });

  it('settles genuine explicit zero without charging the reserved estimate', async () => {
    const a = await account(); const count = provider({ prompt_tokens: 0, completion_tokens: 0 });
    expect((await worker.fetch(request(a.token), env)).status).toBe(200);
    expect((await snapshot(a.userId)).tokensUsed).toBe(0); expect((await ledger(a.userId))[0]?.units).toBe(0);
    expect(count.calls).toBe(1);
  });

  it('serialises concurrent same-key requests before provider spending', async () => {
    const a = await account(); const count = provider();
    const replies = await Promise.all([worker.fetch(request(a.token), env), worker.fetch(request(a.token), env)]);
    expect(replies.map(x => x.status).sort()).toEqual([200, 409]); expect(count.calls).toBe(1);
  });

  it('retained state precedes version, switch, entitlement and quota changes, including legacy decoding', async () => {
    const a = await account(); const count = provider(null);
    expect((await worker.fetch(request(a.token), env)).status).toBe(409);
    await env.DB.prepare("UPDATE entitlements SET status='expired' WHERE user_id=?1").bind(a.userId).run();
    for (const version of ['1', null]) {
      const result = await worker.fetch(request(a.token, KEY, version), { ...env, PAID_ROUTING_DISABLED: 'true',
        PLAN_MONTHLY_POSTPROCESS_TOKENS: '0' });
      expect(await result.json()).toMatchObject({ error: { code: version === null ? 'already_processed' : 'outcome_unknown' } });
    }
    expect(count.calls).toBe(1);
  });

  it('a fresh unsupported version is safely refused before provider admission', async () => {
    const a = await account(); const result = await worker.fetch(request(a.token, KEY, null), env);
    expect(await result.json()).toMatchObject({ error: { code: 'paid_routing_disabled' } });
    expect(await receipt(a.userId)).toBeUndefined(); expect(await ledger(a.userId)).toHaveLength(0);
  });

  it.each(['1', null])('auth/receipt-history failures stay uncertain for contract %s', async version => {
    const a = await account();
    const auth = await worker.fetch(request('invalid-token', KEY, version), env);
    expect(await auth.json()).toMatchObject({ error: { code: version === null ? 'already_processed' : 'outcome_unknown' } });
    vi.spyOn(Repository.prototype, 'claimRequest').mockRejectedValueOnce(new Error('synthetic-lookup-failure'));
    const history = await worker.fetch(request(a.token, KEY, version), env);
    expect(await history.json()).toMatchObject({ error: { code: version === null ? 'already_processed' : 'outcome_unknown' } });
  });
});

describe('durable receipt ownership, periods and alarms', () => {
  it('expires an unconsumed permit and refuses its stale owner', async () => {
    const a = await account(); const item = await reserve(a.userId);
    const stale = await operation(a.userId, { kind: 'operation_start', idempotencyKey: KEY,
      ownerId: item.ownerId, revision: item.revision, nowSeconds: item.expiresAt + 1 });
    expect(stale.ok).toBe(false); expect(stale.receipt?.phase).toBe('not_started');
    expect((await snapshot(a.userId)).tokensUsed).toBe(0);
  });

  it('retains a dispatched hold across expiry and lets only the original owner settle its advanced revision', async () => {
    const a = await account(); let item = await start(a.userId, await reserve(a.userId)); const old = item;
    item = (await operation(a.userId, { kind: 'operation_lookup', idempotencyKey: KEY,
      nowSeconds: item.expiresAt + 1 })).receipt!;
    expect(item.phase).toBe('outcome_unknown'); expect(item.revision).toBeGreaterThan(old.revision);
    expect((await snapshot(a.userId)).tokensMeasured).toBe(0); expect((await snapshot(a.userId)).tokensHeld).toBe(100);
    const measurement = { kind: 'operation_measure' as const, idempotencyKey: KEY, ownerId: item.ownerId,
      revision: old.revision, nowSeconds: item.expiresAt + 2, actualUnits: 60, measuredAt: item.expiresAt + 2 };
    expect((await operation(a.userId, measurement)).ok).toBe(false);
    expect((await operation(a.userId, { ...measurement, revision: item.revision, ownerId: 'foreign-owner' })).ok).toBe(false);
    expect((await operation(a.userId, { ...measurement, revision: item.revision })).ok).toBe(true);
    expect((await snapshot(a.userId)).tokensUsed).toBe(60); expect((await snapshot(a.userId)).tokensHeld).toBe(0);
    expect((await operation(a.userId, { ...measurement, revision: item.revision })).ok).toBe(true);
    expect((await snapshot(a.userId)).tokensUsed).toBe(60);
  });

  it('keeps prior-period holds and late measured settlement outside a new period', async () => {
    const a = await account(); const item = await start(a.userId, await reserve(a.userId, KEY, 100, '2026-09'));
    expect((await snapshot(a.userId, '2026-10')).tokensUsed).toBe(0);
    await measure(a.userId, item, 20);
    expect((await snapshot(a.userId, '2026-09')).tokensUsed).toBe(20);
    expect((await snapshot(a.userId, '2026-10')).tokensUsed).toBe(0);
  });

  it('preserves occupied allowance with a separate exact measured/held breakdown', async () => {
    const a = await account(); await measure(a.userId, await start(a.userId, await reserve(a.userId, KEY, 40)), 20);
    await start(a.userId, await reserve(a.userId, KEY + '-held', 30));
    const state = await snapshot(a.userId);
    expect(state).toMatchObject({ tokensUsed: 50, tokensMeasured: 20, tokensHeld: 30 });
    expect(100 - state.tokensUsed).toBe(50);
  });

  it('does not relabel inherited or legacy-expired committed estimates as verified usage', async () => {
    const a = await account();
    await runInDurableObject(stub(a.userId), async (_instance, state) => {
      await state.storage.put('period:2026-10', { period: '2026-10', audioSecondsCommitted: 0, tokensCommitted: 20 });
    });
    const state = await snapshot(a.userId); expect(state.tokensUsed).toBe(20); expect(state.tokensMeasured).toBeUndefined();
  });

  it('rejects different owners/measurements and isolates the same key across accounts', async () => {
    const a = await account(); const b = await account();
    const first = await start(a.userId, await reserve(a.userId)); await reserve(b.userId);
    const settled = await measure(a.userId, first);
    expect((await operation(a.userId, { kind: 'operation_measure', idempotencyKey: KEY, ownerId: settled.ownerId,
      revision: settled.revision, nowSeconds: now(), actualUnits: 61, measuredAt: settled.measuredAt! })).ok).toBe(false);
    expect((await snapshot(a.userId)).tokensUsed).toBe(60); expect((await snapshot(b.userId)).tokensUsed).toBe(100);
  });

  it('retains a mismatched immutable ledger row as conflict and still reconciles another receipt', async () => {
    const a = await account(); let first = await reserve(a.userId); first = await start(a.userId, first);
    await measure(a.userId, first);
    const second = await start(a.userId, await reserve(a.userId, KEY + '-second'));
    await measure(a.userId, second, 20);
    await new Repository(env.DB).recordUsage({ userId: a.userId, idempotencyKey: KEY, operation: 'post_processing',
      provider: 'openrouter', model: 'openai/gpt-5-mini', unitKind: 'tokens', units: 99,
      billingPeriod: '2026-10', correlationId: 'different', nowSeconds: now() });
    await alarm(a.userId);
    expect((await receipt(a.userId))?.lastFailure).toBe('ledger_conflict');
    expect((await receipt(a.userId, KEY + '-second'))?.phase).toBe('settled');
    expect((await snapshot(a.userId)).tokensUsed).toBe(80);
    expect((await ledger(a.userId)).map(row => row.units).sort()).toEqual([20, 99]);
  });
  it('revokes only an unconsumed owned permit and cannot authorise a second start', async () => {
    const a = await account(); const reserved = await reserve(a.userId);
    const cancelled = await operation(a.userId, { kind: 'operation_cancel', idempotencyKey: KEY,
      ownerId: reserved.ownerId, revision: reserved.revision, nowSeconds: now() });
    expect(cancelled.receipt?.phase).toBe('not_started'); expect((await snapshot(a.userId)).tokensUsed).toBe(0);
    const stale = await operation(a.userId, { kind: 'operation_start', idempotencyKey: KEY,
      ownerId: reserved.ownerId, revision: reserved.revision, nowSeconds: now() });
    expect(stale.ok).toBe(false);
    const started = await start(a.userId, await reserve(a.userId, KEY + '-new'));
    expect((await operation(a.userId, { kind: 'operation_start', idempotencyKey: started.idempotencyKey,
      ownerId: started.ownerId, revision: started.revision, nowSeconds: now() })).ok).toBe(false);
    expect((await operation(a.userId, { kind: 'operation_cancel', idempotencyKey: started.idempotencyKey,
      ownerId: started.ownerId, revision: started.revision, nowSeconds: now() })).ok).toBe(false);
    expect((await snapshot(a.userId)).tokensUsed).toBe(100);
  });

  it('bounds one alarm batch and leaves a durable alarm for remaining receipts', async () => {
    const time = now(); const clock = vi.spyOn(Date, 'now').mockReturnValue(time * 1000);
    const a = await account();
    for (let index = 0; index < 27; index += 1) {
      await measure(a.userId, await start(a.userId, await reserve(a.userId, KEY + '-' + index, 1)), 1);
    }
    // Run the installed alarm with its real due markers. Rewriting them into the
    // past made a second automatic alarm race this assertion and test teardown.
    clock.mockReturnValue((time + 30) * 1000);
    expect(await runDurableObjectAlarm(stub(a.userId))).toBe(true);
    expect(await ledger(a.userId)).toHaveLength(25);
    const next = await runInDurableObject(stub(a.userId), async (_instance, state) => state.storage.getAlarm());
    expect(next).not.toBeNull();
    expect(await runDurableObjectAlarm(stub(a.userId))).toBe(true);
    expect(await ledger(a.userId)).toHaveLength(27);
    expect((await snapshot(a.userId)).tokensUsed).toBe(27);
  });

  it('generic release/finalise cannot bypass ownership of a tracked operation', async () => {
    const a = await account(); const item = await start(a.userId, await reserve(a.userId));
    const quota = new QuotaClient(env.QUOTA, LIMITS);
    await expect(quota.release({ userId: a.userId, reservationId: item.reservationId,
      nowSeconds: now() })).rejects.toThrow();
    await expect(quota.finalise({ userId: a.userId, reservationId: item.reservationId,
      actualUnits: 1, nowSeconds: now() })).rejects.toThrow();
    expect((await snapshot(a.userId)).tokensHeld).toBe(100);
    expect((await snapshot(a.userId)).tokensMeasured).toBe(0);
  });

});

/** These controls use the actual installed alarm, with no receipt timestamp rewrite. */
describe('installed alarm recovery and fairness', () => {
  async function installedAlarm(user: string): Promise<number | null> {
    return runInDurableObject(stub(user), async (_instance, state) => state.storage.getAlarm());
  }

  it('preserves the earlier alarm and lets a later receipt pass a failing receipt in backoff', async () => {
    const time = now(); const clock = vi.spyOn(Date, 'now').mockReturnValue(time * 1000);
    const a = await account();
    await measure(a.userId, await start(a.userId, await reserve(a.userId)), 20);
    expect(await installedAlarm(a.userId)).toBe((time + 30) * 1000);
    clock.mockReturnValue((time + 1) * 1000);
    await measure(a.userId, await start(a.userId, await reserve(a.userId, KEY + '-later')), 30);
    expect(await installedAlarm(a.userId)).toBe((time + 30) * 1000);
    await rejectLedger(); clock.mockReturnValue((time + 30) * 1000);
    expect(await runDurableObjectAlarm(stub(a.userId))).toBe(true);
    expect((await receipt(a.userId))?.nextReconcileAt).toBe(time + 60);
    expect((await receipt(a.userId, KEY + '-later'))?.nextReconcileAt).toBe(time + 31);
    expect(await installedAlarm(a.userId)).toBe((time + 31) * 1000);
    await env.DB.prepare('DROP TRIGGER settlement_fail_ledger').run();
    clock.mockReturnValue((time + 31) * 1000);
    expect(await runDurableObjectAlarm(stub(a.userId))).toBe(true);
    expect((await receipt(a.userId, KEY + '-later'))?.phase).toBe('settled');
    expect((await receipt(a.userId))?.phase).toBe('ledger_pending');
    expect(await installedAlarm(a.userId)).toBe((time + 60) * 1000);
    clock.mockReturnValue((time + 60) * 1000);
    expect(await runDurableObjectAlarm(stub(a.userId))).toBe(true);
    expect((await receipt(a.userId))?.phase).toBe('settled');
    expect(await ledger(a.userId)).toHaveLength(2);
    expect((await snapshot(a.userId)).tokensUsed).toBe(50);
    expect(await installedAlarm(a.userId)).toBeNull();
  });

  const resetCases = (['alarm_ack', 'write_before', 'write_ack'] as const).flatMap(fault =>
    (['buffered', 'flushed'] as const).flatMap(durability => [false, true].map(priorPending =>
      ({ fault, durability, priorPending }))));
  it.each(resetCases)('retains safe durable state after $durability $fault (prior pending: $priorPending)',
    async ({ fault, durability, priorPending }) => {
      const time = now(); const clock = vi.spyOn(Date, 'now').mockReturnValue(time * 1000);
      const a = await account(); const item = await start(a.userId, await reserve(a.userId));
      // A second operation finishes while the first measurement RPC is delayed.
      // Its real, completed RPC creates a later pending marker and installed alarm.
      clock.mockReturnValue((time + 1) * 1000);
      const prior = priorPending ? await measure(a.userId,
        await start(a.userId, await reserve(a.userId, KEY + '-prior')), 30) : undefined;
      const beforeReset = await runInDurableObject(stub(a.userId), async (_instance, state) => {
        await state.storage.sync();
        return { entries: Object.fromEntries(await state.storage.list()), alarm: await state.storage.getAlarm() };
      });
      let injected = false;
      await expect(runInDurableObject(stub(a.userId), async (_instance, state) => {
        // A gate exception resets the real object. Buffered writes may roll back;
        // sync establishes a separate, genuinely committed acknowledgement-loss boundary.
        const interrupt = async (): Promise<never> => {
          if (durability === 'flushed') await state.storage.sync();
          injected = true; throw new Error(`synthetic-${durability}-${fault}`);
        };
        const storage = {
          get: state.storage.get.bind(state.storage),
          getAlarm: state.storage.getAlarm.bind(state.storage),
          setAlarm: async (at: number | Date): Promise<void> => {
            await state.storage.setAlarm(at);
            if (fault === 'alarm_ack') await interrupt();
          },
          put: async (entries: Record<string, unknown>): Promise<void> => {
            if (fault === 'write_before') await interrupt();
            await state.storage.put(entries);
            if (fault === 'write_ack') await interrupt();
          },
        };
        const wrapped = { storage, blockConcurrencyWhile: state.blockConcurrencyWhile.bind(state) };
        const fresh = new QuotaDurableObject(wrapped as unknown as DurableObjectState, env);
        await fresh.fetch(new Request('https://quota.invalid', { method: 'POST', body: JSON.stringify({
          kind: 'operation_measure', idempotencyKey: KEY, ownerId: item.ownerId, revision: item.revision,
          nowSeconds: time, actualUnits: 20, measuredAt: time,
        }) }));
      })).rejects.toThrow();
      // Capture before assertions or a status/lookup RPC can sweep expired state.
      const afterReset = await runInDurableObject(stub(a.userId), async (_instance, state) => ({
        entries: Object.fromEntries(await state.storage.list()), alarm: await state.storage.getAlarm(),
      }));
      const rawLedger = await ledger(a.userId);
      const rawClaims = (await env.DB.prepare(
        'SELECT operation,status FROM request_claims WHERE user_id=?1').bind(a.userId).all()).results;
      console.log('SETTLEMENT_RESET_STATE', JSON.stringify({ fault, durability, priorPending, injected,
        beforeReset, afterReset, ledger: rawLedger, claims: rawClaims }));
      expect(injected).toBe(true); expect(rawLedger).toHaveLength(0); expect(rawClaims).toHaveLength(0);
      const committed = durability === 'flushed' && fault === 'write_ack';
      const held = committed ? 0 : 100;
      expect(afterReset.alarm).toBe(durability === 'flushed' ? (time + 30) * 1000 : beforeReset.alarm);
      if (durability === 'buffered') expect(afterReset).toEqual(beforeReset);
      const restored = afterReset.entries[receiptKey(KEY)] as SettlementReceipt;
      if (committed) expect(restored).toEqual({ ...item, revision: item.revision + 1, phase: 'ledger_pending',
        actualUnits: 20, measuredAt: time, nextReconcileAt: time + 30 });
      else expect(restored).toEqual(item);
      if (prior !== undefined) expect(afterReset.entries[receiptKey(prior.idempotencyKey)]).toEqual(prior);
      const markers = Object.entries(afterReset.entries).filter(([key]) => key.startsWith('settlement_pending:'));
      expect(markers).toHaveLength(Number(priorPending) + Number(committed));
      if (committed) expect(afterReset.entries[pendingKey(restored)]).toBe(KEY);
      if (prior !== undefined) expect(afterReset.entries[pendingKey(prior)]).toBe(prior.idempotencyKey);
      expect(afterReset.entries['period:2026-10']).toMatchObject({ tokensCommitted:
        (priorPending ? 30 : 0) + (committed ? 20 : 0) });
      expect(afterReset.entries['reservations']).toEqual(committed ? [] : beforeReset.entries['reservations']);
      expect((await snapshot(a.userId)).tokensHeld).toBe(held);
      // Any redispatch would hit denied unmatched network; retained state refuses it first.
      const retry = await worker.fetch(request(a.token), env);
      expect(await retry.json()).toMatchObject({ error: { code: committed ? 'settlement_pending' : 'request_in_progress' } });
      if (durability === 'flushed') {
        clock.mockReturnValue((time + 30) * 1000);
        expect(await runDurableObjectAlarm(stub(a.userId))).toBe(true);
        expect(await ledger(a.userId)).toHaveLength(Number(committed));
      }
      if (priorPending) {
        expect(await installedAlarm(a.userId)).toBe((time + 31) * 1000);
        clock.mockReturnValue((time + 31) * 1000);
        expect(await runDurableObjectAlarm(stub(a.userId))).toBe(true);
        expect((await receipt(a.userId, KEY + '-prior'))?.phase).toBe('settled');
      }
      expect(await installedAlarm(a.userId)).toBeNull();
      expect(await ledger(a.userId)).toHaveLength(Number(priorPending) + Number(committed));
      clock.mockReturnValue((time + 61) * 1000);
      const current = await new QuotaClient(env.QUOTA, LIMITS).operationReceipt(a.userId, KEY, time + 61);
      expect(current?.phase).toBe(committed ? 'settled' : 'outcome_unknown');
      expect((await snapshot(a.userId)).tokensHeld).toBe(held);
      // The original owner can recover the same measurement after expiry/reset;
      // this is settlement only, with no second provider admission or quota charge.
      const recovered = await operation(a.userId, { kind: 'operation_measure', idempotencyKey: KEY,
        ownerId: item.ownerId, revision: current!.revision, nowSeconds: time + 61,
        actualUnits: 20, measuredAt: time });
      expect(recovered.ok).toBe(true);
      if (!committed) {
        clock.mockReturnValue((time + 91) * 1000);
        expect(await runDurableObjectAlarm(stub(a.userId))).toBe(true);
      }
      expect((await receipt(a.userId))?.phase).toBe('settled');
      expect(await ledger(a.userId)).toHaveLength(Number(priorPending) + 1);
      expect((await snapshot(a.userId)).tokensUsed).toBe((priorPending ? 30 : 0) + 20);
      expect((await snapshot(a.userId)).tokensHeld).toBe(0);
      expect(await installedAlarm(a.userId)).toBeNull();
    });
});

describe('actual Durable Object instance restart', () => {
  it.each(['reserved', 'provider_started', 'ledger_pending'] as const)(
    'retains %s identity after runtime abort without reopening provider dispatch', async phase => {
      const time = now(); const clock = vi.spyOn(Date, 'now').mockReturnValue(time * 1000);
      const a = await account(); let item = await reserve(a.userId);
      if (phase !== 'reserved') item = await start(a.userId, item);
      if (phase === 'ledger_pending') item = await measure(a.userId, item, 20);
      let previousInstance: unknown;
      await runInDurableObject(stub(a.userId), instance => { previousInstance = instance; });
      // Abort the actual runtime instance, not merely a fresh source wrapper.
      // The triggering RPC may reject as the instance is discarded.
      await runInDurableObject(stub(a.userId), (_instance, state) => {
        state.abort('synthetic-paid-settlement-instance-restart');
      }).catch(() => undefined);
      await runInDurableObject(stub(a.userId), instance => { expect(instance).not.toBe(previousInstance); });
      const restored = await new QuotaClient(env.QUOTA, LIMITS).operationReceipt(a.userId, KEY, time);
      expect(restored).toEqual(item);
      const retry = await worker.fetch(request(a.token), env);
      expect(retry.status).toBe(409); // Unmatched provider access is denied by the test transport.
      if (phase === 'ledger_pending') {
        clock.mockReturnValue((time + 30) * 1000);
        expect(await runDurableObjectAlarm(stub(a.userId))).toBe(true);
        expect((await receipt(a.userId))?.phase).toBe('settled');
        expect((await ledger(a.userId))[0]?.units).toBe(20);
        expect((await snapshot(a.userId)).tokensUsed).toBe(20);
      } else {
        clock.mockReturnValue((time + 61) * 1000);
        const expired = await new QuotaClient(env.QUOTA, LIMITS).operationReceipt(a.userId, KEY, time + 61);
        expect(expired?.phase).toBe(phase === 'reserved' ? 'not_started' : 'outcome_unknown');
        expect((await snapshot(a.userId)).tokensMeasured).toBe(0);
        expect((await snapshot(a.userId)).tokensHeld).toBe(phase === 'reserved' ? 0 : 100);
        expect(await ledger(a.userId)).toHaveLength(0);
      }
    });
});
