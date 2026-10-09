# Paid Access Worker

Cloudflare Worker that backs the Just Speak to It paid subscription tier: Sign in with Apple identity, Stripe and StoreKit entitlements, quota enforcement, and proxying of transcription and post-processing to vendor APIs using credentials the app never sees.

Paid access is a **convenience, not a capability upgrade**. On-device local models and bring-your-own (BYO) API keys remain the default and stay fully supported; nothing in this Worker gates a feature that a BYO or local user can otherwise reach. Confirmed pre-dispatch refusals can fall back. A possibly dispatched operation never silently falls back or retries a provider. This source remains disabled and uncommissioned pending external identity, product, privacy-operation and staging gates.

Ordinary app builds retain their existing shipping entitlements and do not observe or handle paid StoreKit updates while the feature is disabled. An internal feature flag does not commission a signed product. Native Sign in with Apple is unsupported for Developer ID apps ([Apple DTS](https://developer.apple.com/forums/thread/793244)); supported direct identity and App Store signing remain separate commissioning gates.

Operational runbook: [`Docs/paid-access.md`](../../Docs/paid-access.md). User-facing data handling: [`Docs/paid-access-privacy.md`](../../Docs/paid-access-privacy.md).

## Design constraints

These are deliberate and load-bearing. Changing any of them is a design decision, not a refactor.

| Constraint | Why |
| --- | --- |
| Settlement authority is the existing per-user quota Durable Object | Quota and the metadata-only receipt commit atomically. D1 is an idempotent append-only projection protected by UNIQUE constraints and triggers |
| Entitlement history, usage ledger and audit events are append-only | Corrections are new auditable transitions. There is no delete endpoint anywhere in the surface |
| Routing is server-owned | A paid request names an *operation*, never a provider, model or cost. The client cannot influence what runs or what it is charged |
| The client never asserts entitlement | Entitlement is re-read from D1 for fresh paid admission. Retained receipt/history replies take precedence over current entitlement checks; a signed transaction is evidence to verify, not a claim to trust |
| Quota is reserved before work, measured after | A one-shot owner permit precedes batch/post dispatch. Unknown outcomes retain allowance; confirmed measurement atomically replaces the hold, then reconciles to D1 |
| Unsupported operations fail loudly | `unsupported_operation` (HTTP 422). There is no silent downgrade to a cheaper model or to the user's own key |
| Nothing is retried that would bill twice | Providers run once per logical key. Same-owner immutable measurement and D1 projection may retry; neither invokes a provider |
| Audio and transcript text are never persisted or logged | Only metered units (audio seconds, token counts) reach the ledger. A retry of a completed request is told `already_processed` rather than handed a stored response — replaying one would mean keeping transcripts |

## Layout

```text
workers/paid-access/
├── migrations/0001_init.sql     D1 schema, constraints and append-only triggers
├── src/
│   ├── index.ts                 Router. Every route listed explicitly; no catch-all proxy
│   ├── env.ts                   Typed config; parses and validates `vars` once per request
│   ├── context.ts               Per-request context (config, repository, quota, logger, clock)
│   ├── http.ts                  Correlation ids, typed `ApiError`, bounded reads, timeouts
│   ├── logging.ts               Structured logging with hard redaction of credential-shaped keys
│   ├── crypto.ts                WebCrypto helpers; no hand-rolled primitives, no `===` on secrets
│   ├── policy.ts                Canonical "Best" routing policy — single source of truth
│   ├── entitlement.ts           Entitlement state machine and `grantsAccess`
│   ├── quota.ts                 Typed client for the quota Durable Object
│   ├── auth/
│   │   ├── apple-identity.ts    Sign in with Apple identity-token verification (JWKS, nonce)
│   │   ├── apple-jws.ts         DER/X.509 reader and JWS `x5c` chain verifier, pinned to Apple Root CA G3
│   │   ├── session.ts           HS256 access tokens; refresh tokens stored only as SHA-256 hashes
│   │   └── storekit.ts          StoreKit 2 signed transactions and App Store Server Notifications V2
│   ├── billing/stripe.ts        Checkout, Customer Portal and webhook signature verification
│   ├── data/repository.ts       All SQL. Uniqueness is the idempotency mechanism
│   ├── do/
│   │   ├── quota.ts             `QuotaDurableObject` — monthly quota + concurrency, leased reservations
│   │   └── live-session.ts      `LiveSessionDurableObject` — live WebSocket proxy, alarm-bounded
│   ├── providers/index.ts       Upstream proxies; receive a credential and nothing else
│   └── routes/                  auth.ts, billing.ts, paid.ts, webhooks.ts
└── test/                        Vitest on `@cloudflare/vitest-pool-workers`
```

## Local development

```bash
cd workers/paid-access
npm install
npm run migrations:local     # wrangler d1 migrations apply paid-access --local
npm run dev                  # wrangler dev
```

`wrangler dev` reads `wrangler.toml`, which ships with `database_id = "REPLACE_WITH_D1_DATABASE_ID"`. Either paste a real D1 database id in, or run against the local emulated D1:

```bash
npx wrangler dev --local
```

Secrets are not read from `wrangler.toml`. For local runs put them in `.dev.vars` (git-ignored) or pass them on the command line; the Worker fails closed with a 500 and an `event: "config.invalid"` log line if a required secret is missing, and never says which one.

## Tests, typecheck and lint

```bash
npm test          # vitest run
npm run typecheck # tsc --noEmit
npm run lint      # eslint src test
```

Tests run inside the Workers runtime and apply the real migrations to an isolated D1 instance before each suite, so constraint and trigger behaviour is under test rather than a hand-written fixture schema. Test bindings live in `vitest.config.ts`; the placeholder secrets there are obviously fake and must stay that way.

Keep Vitest on 3.2.x and `@cloudflare/vitest-pool-workers` on 0.12.x together.
Pool 0.13+ requires a separate test-harness migration: it removes `defineWorkersConfig`,
`singleWorker`, per-test storage isolation and `fetchMock`.

## Endpoints

Every response is JSON and carries an `x-correlation-id` header. Quote that id when reporting a failure — it is enough to trace a request without any request content.

| Method | Path | Auth | Purpose |
| --- | --- | --- | --- |
| GET | `/v1/health` | none | Liveness |
| POST | `/v1/auth/apple` | none | Exchange a Sign in with Apple identity token for a session; body `{identity_token, nonce, device_label?}` |
| POST | `/v1/auth/refresh` | none | Rotate refresh token; body `{refresh_token}` |
| POST | `/v1/auth/sign-out` | Bearer | Revoke the current session |
| GET | `/v1/entitlement` | Bearer | Entitlement, usage and policy snapshot |
| GET | `/v1/policy` | Bearer | Canonical "Best" routing policy |
| POST | `/v1/billing/stripe/checkout` | Bearer | Body `{channel:"direct"}` → `{checkout_url}` |
| POST | `/v1/billing/stripe/portal` | Bearer | Body `{channel:"direct"}` → `{portal_url}` |
| POST | `/v1/billing/storekit/sync` | Bearer | Body `{signed_transaction, signed_renewal_info?}` |
| POST | `/v1/webhooks/stripe` | Stripe signature | Idempotent |
| POST | `/v1/webhooks/appstore` | Apple JWS signature | Idempotent |
| POST | `/v1/paid/transcribe/batch` | Bearer + `Idempotency-Key` | Raw audio body |
| POST | `/v1/paid/post-process` | Bearer + `Idempotency-Key` | Body `{operation:"post_processing", text, system_prompt?, temperature?}` |
| GET | `/v1/paid/transcribe/live` | Bearer | WebSocket upgrade |
| POST | `/v1/paid/transcribe/live/finalise` | Bearer + `Idempotency-Key` | Body `{session_id}` |

There is no delete endpoint, by design.

### Canonical "Best" policy

`src/policy.ts` is the only place these are defined. The apps may *display* the current choice; they cannot influence it.

| Operation | Provider | Catalogue id | Upstream model | Transport | Metered in |
| --- | --- | --- | --- | --- | --- |
| Live transcription | Deepgram | `deepgram/nova-3-streaming` | `nova-3` | WebSocket | Audio seconds |
| Batch transcription | OpenRouter | `google/gemini-2.0-flash-001` | `google/gemini-2.0-flash-001` | HTTPS | Audio seconds |
| Post-processing | OpenRouter | `openai/gpt-5-mini` | `openai/gpt-5-mini` | HTTPS | Tokens |

### Error codes

| Code | Status | Meaning |
| --- | --- | --- |
| `bad_request` | 400 | Malformed body or missing required field |
| `unauthorized` | 401 | Missing, expired or unverifiable session token |
| `forbidden` | 403 | Authenticated but not permitted |
| `not_found` | 404 | Unknown route |
| `conflict` | 409 | Idempotency or state conflict; the first attempt is still in flight |
| `already_processed` | 409 | Retained operation, including the compatibility reply for an older client when an outcome is uncertain. No additional dispatch; not a claim that the original completed or was charged. No response content is replayed |
| `request_in_progress` | 409 | Contract-v1 client: retained reserved or started operation; no silent fallback |
| `settlement_pending` | 409 | Contract-v1 client: settlement needs confirmation or D1 reconciliation; no silent fallback |
| `outcome_unknown` | 409 | Contract-v1 client: a submitted outcome cannot be proven; no silent fallback |
| `request_not_started` | 409 | A retained revoked permit proves no provider dispatch; configured fallback is safe |
| `entitlement_required` | 402 | No entitlement currently grants paid routing |
| `payload_too_large` | 413 | Body exceeds `MAX_REQUEST_BYTES` |
| `unsupported_operation` | 422 | No Best path exists for the requested operation |
| `quota_exceeded` | 429 | Monthly quota exhausted |
| `too_many_sessions` | 429 | `MAX_CONCURRENT_SESSIONS` reached |
| `paid_routing_disabled` | 503 | Kill switch on; entitlements untouched |
| `upstream_error` | 502 | Vendor returned an error |
| `upstream_timeout` | 504 | Vendor exceeded the configured timeout |
| `internal_error` | 500 | Includes misconfiguration, which never names the bad value |

## Secrets

Set with `wrangler secret put <NAME>` (add `--env staging` or `--env production`). Never in `wrangler.toml`, never in the repository.

| Secret | Required | Purpose |
| --- | --- | --- |
| `SESSION_SIGNING_KEY` | Yes | HS256 key for session access tokens; minimum 32 characters |
| `STRIPE_SECRET_KEY` | Yes | Checkout and Customer Portal calls |
| `STRIPE_WEBHOOK_SECRET` | Yes | `Stripe-Signature` verification |
| `OPENROUTER_API_KEY` | Yes | Batch transcription and post-processing |
| `DEEPGRAM_API_KEY` | Yes | Live transcription |
| `OPENAI_API_KEY` | No | Reserved; not used by the current Best paths |
| `APPSTORE_ROOT_CA_G3_BASE64` | No | Overrides the pinned Apple Root CA G3. Testing only |

Non-secret configuration lives in `[vars]` in `wrangler.toml`: `ENVIRONMENT`, `APPLE_IDENTITY_AUDIENCES`, `APPLE_BUNDLE_IDS`, `SESSION_TTL_SECONDS`, `REFRESH_TTL_SECONDS`, `PLAN_MONTHLY_SECONDS`, `PLAN_MONTHLY_POSTPROCESS_TOKENS`, `MAX_CONCURRENT_SESSIONS`, `MAX_LIVE_SESSION_SECONDS`, `MAX_REQUEST_BYTES`, `UPSTREAM_TIMEOUT_MS`, `LIVE_UPSTREAM_TIMEOUT_MS`, `STRIPE_SUCCESS_URL`, `STRIPE_CANCEL_URL`, `STRIPE_PORTAL_RETURN_URL`, `STRIPE_PRICE_IDS`, `STOREKIT_SUBSCRIPTION_PRODUCT_IDS`, `PAID_ROUTING_DISABLED`.

## Adding a D1 migration

Migrations are **forward-only**. There is no down migration, and a deployed migration is never edited.

```bash
cd workers/paid-access
npx wrangler d1 migrations create paid-access add_something   # creates migrations/0002_add_something.sql
$EDITOR migrations/0002_add_something.sql
npm run migrations:local                                      # apply to the local database
npm test                                                      # suites apply the real migrations
npm run migrations:remote                                     # apply to production D1
npx wrangler d1 migrations apply paid-access-staging --remote --env staging
```

Rules:

- Keep append-only guarantees intact. If a new table records history, add the matching `no_update` / `no_delete` triggers alongside it.
- Add the constraint that gives you idempotency in the same migration as the table, as `webhook_events(provider, event_id)` and `usage_ledger(user_id, idempotency_key)` do.
- To correct data, insert a new transition. Do not `UPDATE` or `DELETE` history; the triggers will refuse anyway.

## Things that will bite you

- **`wrangler dev` without a D1 id.** `database_id` is a placeholder in the committed config. Use `--local`, or paste a real id in and do not commit it.
- **`STRIPE_PRICE_IDS = "price_REPLACE_ME_MONTHLY,price_REPLACE_ME_YEARLY"`.** Checkout fails at Stripe, not at our validation. Replace them per environment before deploying. Every price the plan has ever sold must stay listed: a subscription billing on a price missing from this list is treated as another product's and its webhooks are ignored. The first entry is what Checkout opens with when the client names no price.
- **Deploying without `--env`.** `npx wrangler deploy` targets the development environment. Production is `npx wrangler deploy --env production`.
- **Secrets are per environment.** Setting `STRIPE_SECRET_KEY` on the default environment does not set it for `production`.
- **Log fields are redacted by key name.** Anything matching `authorization|api_key|secret|token|password|signature|cookie|transcript|audio|prompt|text|email` is replaced with `[redacted]`, and strings over 256 characters are truncated. If your field disappears in logs, rename it — do not weaken the pattern.
- **`console.log` bypasses the redaction.** Use the request logger. Never log a request or response body.
- **Do not release a possibly dispatched operation.** Only a reserved, unconsumed permit can be cancelled or expire without a hold. Started operations retain allowance until measured; no blind release in a generic catch.
- **Apple JWS payloads are never merely decoded.** `apple-jws.ts` verifies the whole `x5c` chain against the pinned root. Do not add a "just read the claims" shortcut.
- **StoreKit and Stripe use distinct paths.** Stripe endpoints require the caller-declared `channel:"direct"`; this field does not independently attest the installed build. App Store UI uses StoreKit. Build/channel identity qualification remains open.
- **Quota reservations are upper bounds.** Finalise with the measured amount or the user is over-billed against their monthly allowance.
- **The kill switch is a var, not a secret.** `PAID_ROUTING_DISABLED = "true"` plus a redeploy fails paid routing closed with 503 while entitlements stay intact.


### Review hardening

Post-processing reserves UTF-8 prompt bytes plus framing overhead and a 4,096-token completion budget. The same completion limit is sent upstream. Provider-reported usage is recorded without clipping; explicit zero records zero, while missing or invalid token measurement retains an unknown-outcome allowance hold instead of charging the reserved ceiling. Live sessions persist their measured outcome before quota delivery and retry every 30 seconds until delivery succeeds. A delayed measured settlement corrects an expired reservation's provisional charge.

Subscription event ordering is scoped to the purchase source and reference. Each verified purchase is stored by account, source, and subscription reference. Account access is derived from all active purchases without multiplying the per-account quota. Expiry, refund, and renewal on one purchase cannot remove another purchase. Management uses the existing entitlement's purchase source; App Store builds explain where website subscriptions are managed.

A scheduled job removes up to 1,000 expired request claims every 15 minutes using an expiry index. Apply all migrations before enabling the worker. Claims contain no response bodies or dictated text. Paid routing remains disabled by default pending staging and billing configuration.

### Batch and post-processing settlement contract

The per-user quota object retains six metadata-only states: `reserved` → `provider_started` → `ledger_pending` → `settled`; unconsumed revoked/expired permits become `not_started`, and possibly dispatched unmeasured operations become `outcome_unknown`. An original owner may settle a late measured result after the unknown transition by reading the current revision. A retry never obtains another dispatch permit. Receipts persist across claim pruning, billing-period rollover and object reconstruction. No payload or provider response is retained.

Authentication and retained receipt/legacy history checks precede version, kill-switch, entitlement and quota refusals. Failure to authenticate or read history cannot establish that an already submitted operation never started. Clients sending `X-Paid-Settlement-Contract: 1` receive typed non-fallback outcomes; legacy clients receive the recognised `already_processed` compatibility reply.

The measured quota update, receipt and reconciliation marker share one durable write. A confirmed measurement may return its in-memory result while D1 is pending. Stable ledger identity plus exact immutable-field comparison makes D1 reconciliation idempotent, including lost acknowledgements. The existing alarm pattern processes at most 25 due markers per turn with bounded backoff; an immutable D1 mismatch is retained for operator attention rather than overwritten or retried endlessly.

`*_used` still means occupied allowance (committed plus reserved), so existing clients do not double-deduct holds. Additive `*_measured` and `*_held` fields expose the breakdown; measured totals are omitted when inherited state cannot establish them. Holds belong to their original billing period. No public recovery/manual-settlement endpoint, automatic unknown-amount charge, retention purge, new product rule or live-route activation is added. Unknown-outcome resolution and external commissioning remain open gates.
