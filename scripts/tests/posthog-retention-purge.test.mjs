import assert from 'node:assert/strict';
import {test} from 'node:test';
import {buildQuery, computeCutoff, listStatuses, resolveHost, run, submissionId} from '../../.github/scripts/posthog-retention-purge.mjs';

const KEY = 'phx_secret_test_key_do_not_log';
const NOW = new Date('2026-11-07T18:00:00Z');
const env = (extra = {}) => ({POSTHOG_PURGE_API_KEY: KEY, POSTHOG_PROJECT_ID: '12345', ...extra});
const json = (status, body) => ({status, json: async () => body});

function fakeFetch({previewCount = 3, create = json(201, {id: 'r1', status: 'pending'}), pages} = {}) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push({url, method: init.method, body: init.body, auth: init.headers.Authorization});
    const u = new URL(url);
    if (init.method === 'GET' && u.pathname.endsWith('/data_deletion_requests/')) {
      const page = Number(u.searchParams.get('page') ?? 0);
      return (pages ?? [json(200, {count: 0, next: null, results: []})])[page];
    }
    if (init.method === 'POST' && u.pathname.endsWith('/preview/')) return json(200, {count: previewCount});
    if (init.method === 'POST' && u.pathname.endsWith('/data_deletion_requests/')) return create;
    throw new Error(`unexpected ${init.method} ${url}`);
  };
  return {fetch, calls};
}

async function runWith(options) {
  const lines = [];
  const code = await run({now: NOW, log: (l) => lines.push(l), ...options});
  return {code, out: lines.join('\n')};
}

test('missing key or project id is a no-op notice with exit 0', async () => {
  for (const e of [{}, {POSTHOG_PURGE_API_KEY: KEY}, {POSTHOG_PROJECT_ID: '1'}]) {
    const {fetch, calls} = fakeFetch();
    const {code, out} = await runWith({env: e, fetch});
    assert.equal(code, 0);
    assert.match(out, /not configured/);
    assert.equal(calls.length, 0);
  }
});

test('host allowlist accepts only PostHog EU/US Cloud over https', () => {
  assert.equal(resolveHost(undefined), 'https://eu.posthog.com');
  assert.equal(resolveHost('https://us.posthog.com/'), 'https://us.posthog.com');
  for (const h of ['http://eu.posthog.com', 'https://evil.example', 'https://eu.posthog.com.evil.example',
    'https://app.posthog.com', 'https://eu.posthog.com:8443', 'https://user@eu.posthog.com', 'nope']) {
    assert.throws(() => resolveHost(h), /POSTHOG_HOST/);
  }
});

test('disallowed host fails closed without any request', async () => {
  const {fetch, calls} = fakeFetch();
  const {code} = await runWith({env: env({POSTHOG_HOST: 'https://evil.example'}), fetch});
  assert.equal(code, 1);
  assert.equal(calls.length, 0);
});

test('cutoff is midnight UTC at or before now minus retention days', () => {
  assert.equal(computeCutoff(NOW, 365).toISOString(), '2025-11-07T00:00:00.000Z');
  assert.equal(computeCutoff(new Date('2026-03-01T00:30:00Z'), 365).toISOString(), '2025-03-01T00:00:00.000Z');
  assert.equal(buildQuery('retention', computeCutoff(NOW, 365)),
    "SELECT uuid FROM events WHERE timestamp < toDateTime('2025-11-07T00:00:00Z')");
});

test('dry run previews and lists but never submits or deletes', async () => {
  const {fetch, calls} = fakeFetch({previewCount: 42});
  const {code, out} = await runWith({env: env(), fetch});
  assert.equal(code, 0);
  assert.match(out, /Matching events: 42/);
  assert.match(out, /Dry run/);
  assert.deepEqual(calls.map((c) => c.method), ['GET', 'POST']);
  assert.ok(calls.every((c) => c.method !== 'DELETE'));
  assert.match(calls[1].url, /\/preview\/$/);
  assert.ok(calls.every((c) => new URL(c.url).origin === 'https://eu.posthog.com'));
});

test('live run submits one idempotent request with the retention query', async () => {
  const {fetch, calls} = fakeFetch();
  const {code, out} = await runWith({env: env({DRY_RUN: 'false'}), fetch});
  assert.equal(code, 0);
  assert.match(out, /submitted; status: pending/);
  assert.match(out, /::warning::Deletion request is awaiting PostHog approval.*eu\.posthog\.com\/#panel=support/);
  const create = calls.at(-1);
  assert.equal(create.method, 'POST');
  assert.match(create.url, /\/api\/projects\/12345\/data_deletion_requests\/$/);
  const body = JSON.parse(create.body);
  assert.match(body.query, /timestamp < toDateTime\('2025-11-07T00:00:00Z'\)/);
  assert.equal(body.submission_id, submissionId('12345', body.query));
  assert.match(body.submission_id, /^[0-9a-f]{8}-[0-9a-f]{4}-5[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/);
});

test('pending requests already in PostHog are reported with an approval warning', async () => {
  const pages = [json(200, {count: 3, next: null, results: [{status: 'pending'}, {status: 'pending'}, {status: 'completed'}]})];
  const {fetch} = fakeFetch({pages, previewCount: 0});
  const {code, out} = await runWith({env: env(), fetch});
  assert.equal(code, 0);
  assert.match(out, /completed=1, pending=2/);
  assert.match(out, /::warning::2 deletion request\(s\) awaiting PostHog approval/);
});

test('a failed create status fails the run and a new attempt salts the submission id', async () => {
  const failed = fakeFetch({create: json(200, {id: 'r1', status: 'failed'})});
  const {code, out} = await runWith({env: env({DRY_RUN: 'false'}), fetch: failed.fetch});
  assert.equal(code, 1);
  assert.match(out, /failed in PostHog; rerun with PURGE_ATTEMPT=2/);
  const first = JSON.parse(failed.calls.at(-1).body).submission_id;

  const retry = fakeFetch({create: json(201, {id: 'r2', status: 'approved'})});
  const again = await runWith({env: env({DRY_RUN: 'false', PURGE_ATTEMPT: '2'}), fetch: retry.fetch});
  assert.equal(again.code, 0);
  assert.doesNotMatch(again.out, /::warning::/);
  const second = JSON.parse(retry.calls.at(-1).body).submission_id;
  assert.notEqual(second, first);
  assert.equal(submissionId('12345', 'q', 1), submissionId('12345', 'q'));

  const bad = fakeFetch();
  assert.equal((await runWith({env: env({PURGE_ATTEMPT: '0'}), fetch: bad.fetch})).code, 1);
  assert.equal(bad.calls.length, 0);
});

test('zero matches submits nothing even when live', async () => {
  const {fetch, calls} = fakeFetch({previewCount: 0});
  assert.equal((await runWith({env: env({DRY_RUN: 'false'}), fetch})).code, 0);
  assert.equal(calls.filter((c) => c.method === 'POST').length, 1);
});

test('geoip mode targets GeoIP properties and refuses above the expected maximum', async () => {
  const ok = fakeFetch({previewCount: 7});
  assert.equal((await runWith({env: env({PURGE_MODE: 'geoip-test-events', DRY_RUN: 'false'}), fetch: ok.fetch})).code, 0);
  const q = JSON.parse(ok.calls.at(-1).body).query;
  assert.match(q, /\$geoip_city_name/);
  assert.match(q, /\$geoip_postal_code/);
  const tooMany = fakeFetch({previewCount: 8});
  const {code, out} = await runWith({env: env({PURGE_MODE: 'geoip-test-events', DRY_RUN: 'false'}), fetch: tooMany.fetch});
  assert.equal(code, 1);
  assert.match(out, /refusing/);
  assert.equal(tooMany.calls.filter((c) => c.method === 'POST').length, 1);
});

test('pagination is bounded and must stay on the configured origin', async () => {
  const origin = 'https://eu.posthog.com';
  const page = (i) => json(200, {count: 999, next: `${origin}/api/projects/1/data_deletion_requests/?page=${i + 1}`,
    results: [{status: 'completed'}]});
  const endless = fakeFetch({pages: Array.from({length: 20}, (_, i) => page(i))});
  await assert.rejects(listStatuses(endless.fetch, origin, '1', KEY, 3), /exceeded 3 pages/);
  assert.equal(endless.calls.length, 3);

  const finite = fakeFetch({pages: [page(0), json(200, {count: 2, next: null, results: [{status: 'pending'}]})]});
  assert.deepEqual(await listStatuses(finite.fetch, origin, '1', KEY), {completed: 1, pending: 1});

  const foreign = fakeFetch({pages: [json(200, {count: 2, next: 'https://evil.example/x', results: []})]});
  await assert.rejects(listStatuses(foreign.fetch, origin, '1', KEY), /pagination/);
});

test('unexpected responses fail closed before any submission', async () => {
  for (const pages of [[json(500, {})], [json(200, {results: 'x'})], [json(200, {count: 1, next: null, results: [{status: 'weird'}]})]]) {
    const {fetch, calls} = fakeFetch({pages});
    assert.equal((await runWith({env: env({DRY_RUN: 'false'}), fetch})).code, 1);
    assert.equal(calls.filter((c) => c.method === 'POST').length, 0);
  }
  const badCreate = fakeFetch({create: json(400, {detail: 'bad'})});
  assert.equal((await runWith({env: env({DRY_RUN: 'false'}), fetch: badCreate.fetch})).code, 1);
  const conflict = fakeFetch({create: json(409, {detail: 'busy'})});
  const deferred = await runWith({env: env({DRY_RUN: 'false'}), fetch: conflict.fetch});
  assert.equal(deferred.code, 0);
  assert.match(deferred.out, /::warning::PostHog deferred/);
  const invalid = fakeFetch();
  assert.equal((await runWith({env: env({DRY_RUN: 'maybe'}), fetch: invalid.fetch})).code, 1);
  assert.equal(invalid.calls.length, 0);
});

test('the API key is sent only as a header and never printed', async () => {
  const outputs = [];
  for (const e of [env(), env({DRY_RUN: 'false'}), env({POSTHOG_HOST: 'https://evil.example'})]) {
    const {fetch, calls} = fakeFetch();
    outputs.push((await runWith({env: e, fetch})).out);
    for (const c of calls) {
      assert.equal(c.auth, `Bearer ${KEY}`);
      assert.ok(!c.url.includes(KEY));
      assert.ok(!(c.body ?? '').includes(KEY));
    }
  }
  const throwing = async () => { throw new Error(`boom ${KEY}`); };
  outputs.push((await runWith({env: env(), fetch: throwing})).out);
  for (const out of outputs) assert.ok(!out.includes(KEY));
});
