import { defineWorkersConfig, readD1Migrations } from '@cloudflare/vitest-pool-workers/config';
import path from 'node:path';

// Migrations are read at config time and handed to the test worker, which
// applies them to the isolated D1 instance before each suite. Tests therefore
// exercise the same constraints and triggers that production runs.
const migrations = await readD1Migrations(path.join(import.meta.dirname, 'migrations'));

export default defineWorkersConfig({
  test: {
    setupFiles: ['./test/setup.ts'],
    poolOptions: {
      workers: {
        singleWorker: true,
        wrangler: { configPath: './wrangler.toml' },
        miniflare: {
          compatibilityFlags: ['nodejs_compat'],
          bindings: {
            TEST_MIGRATIONS: migrations,
            SESSION_SIGNING_KEY: 'test-session-signing-key-that-is-long-enough',
            STRIPE_SECRET_KEY: 'sk_test_placeholder',
            STRIPE_WEBHOOK_SECRET: 'whsec_test_placeholder',
            OPENROUTER_API_KEY: 'test-openrouter-key',
            DEEPGRAM_API_KEY: 'test-deepgram-key',
            // Deployed environments ship with the kill switch on until billing
            // setup is verified; the suites exercise the enabled path.
            PAID_ROUTING_DISABLED: 'false',
          },
        },
      },
    },
  },
});
