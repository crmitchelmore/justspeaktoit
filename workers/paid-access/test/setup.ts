import { applyD1Migrations, env } from 'cloudflare:test';
import { beforeEach } from 'vitest';
import type { Env } from '../src/env.js';

declare module 'cloudflare:test' {
  interface ProvidedEnv extends Env {
    TEST_MIGRATIONS: D1Migration[];
  }
}

// Each test starts from a migrated but empty database. Applying the real
// migrations (rather than a hand-written fixture schema) means constraint and
// trigger behaviour is under test too.
beforeEach(async () => {
  for (const table of [
    'audit_events',
    'entitlement_events',
    'usage_ledger',
    'webhook_events',
    'billing_customers',
    'entitlements',
    'auth_sessions',
    'users',
  ]) {
    await env.DB.prepare(`DROP TABLE IF EXISTS ${table}`).run();
  }
  await env.DB.prepare('DELETE FROM d1_migrations').run().catch(() => undefined);
  await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
});
