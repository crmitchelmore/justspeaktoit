import { cloudflareTest, readD1Migrations } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';
import path from 'node:path';

// Migrations are read at config time and handed to the test worker, which
// applies them to the isolated D1 instance before each suite. Tests therefore
// exercise the same constraints and triggers that production runs.
const migrations = await readD1Migrations(path.join(import.meta.dirname, 'migrations'));

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: './wrangler.toml' },
      miniflare: {
        // Vitest observes Node rejection events; let same-checkpoint catches attach first.
        compatibilityFlags: ['nodejs_compat', 'unhandled_rejection_after_microtask_checkpoint'],
        bindings: {
          TEST_MIGRATIONS: migrations,
          SESSION_SIGNING_KEY: 'test-session-signing-key-that-is-long-enough',
          // Deliberately not shaped like real Stripe credentials: a literal
          // starting `sk_`/`whsec_` trips secret scanners on every commit.
          STRIPE_SECRET_KEY: 'test-not-a-real-key',
          STRIPE_WEBHOOK_SECRET: 'test-not-a-real-webhook-secret',
          OPENROUTER_API_KEY: 'test-openrouter-key',
          DEEPGRAM_API_KEY: 'test-deepgram-key',
          // Deployed environments ship with the kill switch on until billing
          // setup is verified; the suites exercise the enabled path.
          PAID_ROUTING_DISABLED: 'false',
        },
      },
    }),
  ],
  test: {
    setupFiles: ['./test/setup.ts'],
    fileParallelism: false,
  },
});
