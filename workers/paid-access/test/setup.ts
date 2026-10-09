import { applyD1Migrations, reset } from 'cloudflare:test';
import type { D1Migration } from 'cloudflare:test';
import { env } from 'cloudflare:workers';
import { afterEach, beforeEach, vi } from 'vitest';
import type { Env as WorkerEnv } from '../src/env.js';
import { installUpstreamMock, verifyUpstreamMock } from './upstream.js';

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace -- Workers bindings augment Cloudflare.Env.
  namespace Cloudflare {
    interface Env extends WorkerEnv {
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}

// Each test starts from a migrated but empty database. Applying the real
// migrations (rather than a hand-written fixture schema) means constraint and
// trigger behaviour is under test too.
beforeEach(async () => {
  await reset();
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
  installUpstreamMock();
});

afterEach(async () => {
  try {
    verifyUpstreamMock();
  } finally {
    vi.restoreAllMocks();
    vi.unstubAllGlobals();
    await reset();
  }
});
