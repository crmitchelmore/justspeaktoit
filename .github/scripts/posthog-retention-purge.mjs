#!/usr/bin/env node
// Enforces the published 12-month retention promise for raw PostHog events (#776).
//
// Uses PostHog's self-service event deletion API (Data Deletion Requests):
//   https://posthog.com/docs/api/data-deletion-requests
//   POST /api/projects/{project_id}/data_deletion_requests/preview/  -> {count}
//   POST /api/projects/{project_id}/data_deletion_requests/          -> request (idempotent submission_id)
//   GET  /api/projects/{project_id}/data_deletion_requests/           -> paginated status list
// Each takes a one-column HogQL query selecting event UUIDs. PostHog holds new
// requests for staff approval and then deletes asynchronously, so a successful
// run means "submitted" (or deferred/awaiting approval), not "already erased". Output is limited to counts and statuses: never keys,
// distinct IDs, person properties, queries' results or event contents.
import {createHash} from 'node:crypto';
import {pathToFileURL} from 'node:url';

export const ALLOWED_HOSTS = new Set(['eu.posthog.com', 'us.posthog.com']);
export const DEFAULT_HOST = 'https://eu.posthog.com';
export const DEFAULT_RETENTION_DAYS = 365;
// The one-off geoip-test-events mode was retired on 13 Nov 2026: the owner kept GeoIP on and
// disclosed it, and the retention mode deletes those events once they pass 12 months.
export const MODES = new Set(['retention']);
export const MAX_LIST_PAGES = 10;
export const LIST_PAGE_SIZE = 100;
export const REQUEST_TIMEOUT_MS = 30_000;
const STATUSES = new Set(['draft', 'pending', 'approved', 'in_progress', 'queued', 'completed', 'failed']);
const DAY_MS = 86_400_000;
// PostHog creates HogQL event-deletion requests as pending with requires_approval=True, and
// its auto-approval sweep skips them; only PostHog staff can approve (internal admin console).
// https://github.com/PostHog/posthog/blob/master/posthog/data_deletion.py
const approvalHint = (origin) => `Only PostHog staff can approve it: ask via ${origin}/#panel=support.`;

export class PurgeError extends Error {}

export function parseBoolean(value, fallback) {
  if (value === undefined || value === '') return fallback;
  const v = String(value).trim().toLowerCase();
  if (v === 'true' || v === '1') return true;
  if (v === 'false' || v === '0') return false;
  throw new PurgeError('DRY_RUN must be true or false');
}

export function resolveHost(value) {
  let url;
  try {
    url = new URL(value || DEFAULT_HOST);
  } catch {
    throw new PurgeError('POSTHOG_HOST is not a valid URL');
  }
  if (url.protocol !== 'https:' || !ALLOWED_HOSTS.has(url.hostname) || url.port || url.username || url.password) {
    throw new PurgeError('POSTHOG_HOST must be https://eu.posthog.com or https://us.posthog.com');
  }
  return url.origin;
}

export function parseRetentionDays(value) {
  if (value === undefined || value === '') return DEFAULT_RETENTION_DAYS;
  if (!/^\d+$/.test(String(value).trim())) throw new PurgeError('RETENTION_DAYS must be a whole number');
  const days = Number(value);
  if (days < 30 || days > 3650) throw new PurgeError('RETENTION_DAYS must be between 30 and 3650');
  return days;
}

// Midnight UTC at or before (now - retentionDays), so reruns on the same day reuse one cutoff.
export function computeCutoff(now, retentionDays) {
  const ms = now.getTime() - retentionDays * DAY_MS;
  if (!Number.isFinite(ms)) throw new PurgeError('invalid clock');
  return new Date(Math.floor(ms / DAY_MS) * DAY_MS);
}

export function buildQuery(mode, cutoff) {
  if (mode === 'retention') {
    const iso = cutoff.toISOString().replace('.000Z', 'Z');
    if (!/^\d{4}-\d{2}-\d{2}T00:00:00Z$/.test(iso)) throw new PurgeError('invalid cutoff');
    return `SELECT uuid FROM events WHERE timestamp < toDateTime('${iso}')`;
  }
  throw new PurgeError('unknown mode');
}

// Deterministic UUID so a rerun with the same inputs maps to the same PostHog submission.
// PostHog returns the existing request for a reused submission_id, so after a terminal
// failure a new attempt number is needed to submit a fresh request.
export function submissionId(projectId, query, attempt = 1) {
  const salt = attempt === 1 ? '' : `\nattempt ${attempt}`;
  const h = createHash('sha256').update(`justspeaktoit-posthog-purge\n${projectId}\n${query}${salt}`).digest('hex');
  const variant = ((parseInt(h[16], 16) & 0x3) | 0x8).toString(16);
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-${variant}${h.slice(17, 20)}-${h.slice(20, 32)}`;
}

function isCount(value) {
  return Number.isSafeInteger(value) && value >= 0;
}

async function call(fetchImpl, url, {method = 'GET', key, body}) {
  let response;
  try {
    response = await fetchImpl(url, {
      method,
      headers: {
        Authorization: `Bearer ${key}`,
        Accept: 'application/json',
        ...(body ? {'Content-Type': 'application/json'} : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
      redirect: 'error',
      signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS),
    });
  } catch (error) {
    throw new PurgeError(`${method} request failed (${error?.name ?? 'Error'})`);
  }
  let json = null;
  try {
    json = await response.json();
  } catch {
    json = null;
  }
  return {status: response.status, json};
}

export async function listStatuses(fetchImpl, origin, projectId, key, maxPages = MAX_LIST_PAGES) {
  const counts = {};
  let url = `${origin}/api/projects/${projectId}/data_deletion_requests/?limit=${LIST_PAGE_SIZE}`;
  for (let page = 0; url; page++) {
    if (page >= maxPages) throw new PurgeError(`deletion request list exceeded ${maxPages} pages`);
    const {status, json} = await call(fetchImpl, url, {key});
    if (status !== 200 || !json || !Array.isArray(json.results) || !isCount(json.count)) {
      throw new PurgeError(`unexpected list response (HTTP ${status})`);
    }
    for (const item of json.results) {
      if (!item || !STATUSES.has(item.status)) throw new PurgeError('unexpected deletion request status');
      counts[item.status] = (counts[item.status] ?? 0) + 1;
    }
    if (json.next === null || json.next === undefined) break;
    if (typeof json.next !== 'string' || new URL(json.next).origin !== origin) {
      throw new PurgeError('unexpected pagination link');
    }
    url = json.next;
  }
  return counts;
}

export async function run({env = process.env, fetch: fetchImpl = globalThis.fetch, now = new Date(), log = console.log} = {}) {
  const key = (env.POSTHOG_PURGE_API_KEY ?? '').trim();
  const projectId = (env.POSTHOG_PROJECT_ID ?? '').trim();
  if (!key || !projectId) {
    log('PostHog retention purge not configured (POSTHOG_PURGE_API_KEY or POSTHOG_PROJECT_ID missing); nothing to do.');
    return 0;
  }
  try {
    if (!/^\d{1,12}$/.test(projectId)) throw new PurgeError('POSTHOG_PROJECT_ID must be numeric');
    const origin = resolveHost(env.POSTHOG_HOST);
    const mode = (env.PURGE_MODE || 'retention').trim();
    if (!MODES.has(mode)) throw new PurgeError('PURGE_MODE must be retention');
    const dryRun = parseBoolean(env.DRY_RUN, true);
    const retentionDays = parseRetentionDays(env.RETENTION_DAYS);
    const attemptText = (env.PURGE_ATTEMPT ?? '').trim() || '1';
    if (!/^[1-9]\d{0,2}$/.test(attemptText)) throw new PurgeError('PURGE_ATTEMPT must be a whole number from 1 to 999');
    const attempt = Number(attemptText);

    const cutoff = computeCutoff(now, retentionDays);
    const query = buildQuery(mode, cutoff);
    const base = `${origin}/api/projects/${projectId}/data_deletion_requests/`;
    log(`Mode: ${mode}; dry run: ${dryRun}; host: ${new URL(origin).hostname}`);
    log(`Cutoff: events before ${cutoff.toISOString()} (${retentionDays} days)`);

    const existing = await listStatuses(fetchImpl, origin, projectId, key);
    const summary = Object.keys(existing).sort().map((s) => `${s}=${existing[s]}`).join(', ');
    log(`Existing deletion requests by status: ${summary || 'none'}`);
    if (existing.pending) log(`::warning::${existing.pending} deletion request(s) awaiting PostHog approval. ${approvalHint(origin)}`);
    if (existing.failed) log(`::warning::${existing.failed} earlier deletion request(s) failed in PostHog.`);

    const preview = await call(fetchImpl, `${base}preview/`, {method: 'POST', key, body: {query}});
    if (preview.status !== 200 || !preview.json || !isCount(preview.json.count)) {
      throw new PurgeError(`unexpected preview response (HTTP ${preview.status})`);
    }
    const count = preview.json.count;
    log(`Matching events: ${count}`);
    if (count === 0) {
      log('Nothing to delete.');
      return 0;
    }
    if (dryRun) {
      log('Dry run: no deletion request submitted.');
      return 0;
    }

    const created = await call(fetchImpl, base, {
      method: 'POST',
      key,
      body: {query, submission_id: submissionId(projectId, query, attempt)},
    });
    if (created.status === 409) {
      log('::warning::PostHog deferred the deletion request (HTTP 409: active-request limit or submission conflict); will retry next run.');
      return 0;
    }
    if ((created.status !== 200 && created.status !== 201) || !created.json
      || typeof created.json.id !== 'string' || !STATUSES.has(created.json.status)) {
      throw new PurgeError(`unexpected create response (HTTP ${created.status})`);
    }
    const state = created.json.status;
    log(`Deletion request ${created.status === 201 ? 'submitted' : 'already submitted'}; status: ${state}`);
    if (state === 'failed') {
      throw new PurgeError(`deletion request failed in PostHog; rerun with PURGE_ATTEMPT=${attempt + 1} to submit a new one`);
    }
    if (state === 'pending') log(`::warning::Deletion request is awaiting PostHog approval. ${approvalHint(origin)}`);
    return 0;
  } catch (error) {
    const message = error instanceof PurgeError ? error.message : 'unexpected error';
    log(`::error::PostHog retention purge failed: ${message}`);
    return 1;
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  process.exitCode = await run();
}
