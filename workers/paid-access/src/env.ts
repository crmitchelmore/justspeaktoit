/**
 * Typed configuration.
 *
 * `Env` is the raw binding surface Cloudflare hands us; everything reachable
 * from application code goes through `loadConfig`, which parses and validates
 * the untyped `vars` strings once per request. A misconfigured deployment
 * therefore fails loudly at the edge of the system rather than deep inside a
 * billing or quota code path.
 */

export interface Env {
  // Bindings
  DB: D1Database;
  QUOTA: DurableObjectNamespace;
  LIVE_SESSION: DurableObjectNamespace;

  // Non-secret vars (see wrangler.toml)
  ENVIRONMENT: string;
  APPLE_IDENTITY_AUDIENCES: string;
  APPLE_BUNDLE_IDS: string;
  SESSION_TTL_SECONDS: string;
  REFRESH_TTL_SECONDS: string;
  PLAN_MONTHLY_SECONDS: string;
  PLAN_MONTHLY_POSTPROCESS_TOKENS: string;
  MAX_CONCURRENT_SESSIONS: string;
  MAX_LIVE_SESSION_SECONDS: string;
  MAX_REQUEST_BYTES: string;
  UPSTREAM_TIMEOUT_MS: string;
  LIVE_UPSTREAM_TIMEOUT_MS: string;
  STRIPE_SUCCESS_URL: string;
  STRIPE_CANCEL_URL: string;
  STRIPE_PORTAL_RETURN_URL: string;
  /** Comma-separated. The first entry is the price Checkout opens with. */
  STRIPE_PRICE_IDS: string;
  STOREKIT_SUBSCRIPTION_PRODUCT_IDS: string;
  PAID_ROUTING_DISABLED: string;

  // Secrets — `wrangler secret put`, never in wrangler.toml.
  SESSION_SIGNING_KEY?: string;
  STRIPE_SECRET_KEY?: string;
  STRIPE_WEBHOOK_SECRET?: string;
  APPSTORE_ROOT_CA_G3_BASE64?: string;
  OPENAI_API_KEY?: string;
  OPENROUTER_API_KEY?: string;
  DEEPGRAM_API_KEY?: string;
}

export type ProviderSecretName = 'OPENAI_API_KEY' | 'OPENROUTER_API_KEY' | 'DEEPGRAM_API_KEY';

export interface Config {
  environment: string;
  appleIdentityAudiences: readonly string[];
  appleBundleIds: readonly string[];
  sessionTtlSeconds: number;
  refreshTtlSeconds: number;
  planMonthlySeconds: number;
  planMonthlyPostProcessTokens: number;
  maxConcurrentSessions: number;
  maxLiveSessionSeconds: number;
  maxRequestBytes: number;
  upstreamTimeoutMs: number;
  liveUpstreamTimeoutMs: number;
  stripeSuccessUrl: string;
  stripeCancelUrl: string;
  stripePortalReturnUrl: string;
  /**
   * Every price this plan sells — monthly, yearly, and any grandfathered price
   * still billing. A subscription is ours if it bills on any of them; a single
   * id would reject a yearly subscriber's webhooks as another product's.
   */
  stripePriceIds: readonly string[];
  storeKitProductIds: readonly string[];
  paidRoutingDisabled: boolean;
}

export class ConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ConfigurationError';
  }
}

function requiredString(env: Env, key: keyof Env): string {
  const value = env[key];
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new ConfigurationError(`Missing configuration value: ${String(key)}`);
  }
  return value.trim();
}

function boundedInt(env: Env, key: keyof Env, min: number, max: number): number {
  const raw = requiredString(env, key);
  const parsed = Number.parseInt(raw, 10);
  if (!Number.isFinite(parsed) || String(parsed) !== raw) {
    throw new ConfigurationError(`Configuration value ${String(key)} is not an integer`);
  }
  if (parsed < min || parsed > max) {
    throw new ConfigurationError(
      `Configuration value ${String(key)} must be between ${min} and ${max}`,
    );
  }
  return parsed;
}

function csv(env: Env, key: keyof Env): readonly string[] {
  const values = requiredString(env, key)
    .split(',')
    .map((entry) => entry.trim())
    .filter((entry) => entry.length > 0);
  if (values.length === 0) {
    throw new ConfigurationError(`Configuration value ${String(key)} must list at least one entry`);
  }
  return Object.freeze(values);
}

function httpsUrl(env: Env, key: keyof Env): string {
  const value = requiredString(env, key);
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    throw new ConfigurationError(`Configuration value ${String(key)} is not a URL`);
  }
  if (parsed.protocol !== 'https:') {
    throw new ConfigurationError(`Configuration value ${String(key)} must be https`);
  }
  return value;
}

export function loadConfig(env: Env): Config {
  return {
    environment: requiredString(env, 'ENVIRONMENT'),
    appleIdentityAudiences: csv(env, 'APPLE_IDENTITY_AUDIENCES'),
    appleBundleIds: csv(env, 'APPLE_BUNDLE_IDS'),
    sessionTtlSeconds: boundedInt(env, 'SESSION_TTL_SECONDS', 60, 86_400),
    refreshTtlSeconds: boundedInt(env, 'REFRESH_TTL_SECONDS', 3_600, 31_536_000),
    planMonthlySeconds: boundedInt(env, 'PLAN_MONTHLY_SECONDS', 0, 100_000_000),
    planMonthlyPostProcessTokens: boundedInt(
      env,
      'PLAN_MONTHLY_POSTPROCESS_TOKENS',
      0,
      10_000_000_000,
    ),
    maxConcurrentSessions: boundedInt(env, 'MAX_CONCURRENT_SESSIONS', 1, 32),
    maxLiveSessionSeconds: boundedInt(env, 'MAX_LIVE_SESSION_SECONDS', 30, 14_400),
    maxRequestBytes: boundedInt(env, 'MAX_REQUEST_BYTES', 1_024, 104_857_600),
    upstreamTimeoutMs: boundedInt(env, 'UPSTREAM_TIMEOUT_MS', 1_000, 300_000),
    liveUpstreamTimeoutMs: boundedInt(env, 'LIVE_UPSTREAM_TIMEOUT_MS', 1_000, 120_000),
    stripeSuccessUrl: httpsUrl(env, 'STRIPE_SUCCESS_URL'),
    stripeCancelUrl: httpsUrl(env, 'STRIPE_CANCEL_URL'),
    stripePortalReturnUrl: httpsUrl(env, 'STRIPE_PORTAL_RETURN_URL'),
    stripePriceIds: csv(env, 'STRIPE_PRICE_IDS'),
    storeKitProductIds: csv(env, 'STOREKIT_SUBSCRIPTION_PRODUCT_IDS'),
    paidRoutingDisabled: requiredString(env, 'PAID_ROUTING_DISABLED').toLowerCase() === 'true',
  };
}

/**
 * Least-privilege access to vendor credentials.
 *
 * Provider proxies never receive `Env`; they receive a resolver that can hand
 * out exactly one named secret. That keeps a compromised or careless provider
 * module from reaching Stripe keys or the session signing key, and makes every
 * credential use greppable at the call site.
 */
export type SecretResolver = (name: ProviderSecretName) => string;

export function providerSecretResolver(env: Env, allowed: readonly ProviderSecretName[]) {
  const permitted = new Set(allowed);
  return (name: ProviderSecretName): string => {
    if (!permitted.has(name)) {
      throw new ConfigurationError(`Secret ${name} is not available to this operation`);
    }
    const value = env[name];
    if (typeof value !== 'string' || value.length === 0) {
      throw new ConfigurationError(`Secret ${name} is not configured`);
    }
    return value;
  };
}

export function requireSecret(env: Env, name: keyof Env): string {
  const value = env[name];
  if (typeof value !== 'string' || value.length === 0) {
    throw new ConfigurationError(`Secret ${String(name)} is not configured`);
  }
  return value;
}
