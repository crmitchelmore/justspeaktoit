-- Paid Access schema.
--
-- D1 is treated as a safety boundary, not just storage: every invariant that
-- protects money or entitlement state is expressed as a constraint here so a
-- logic bug in the Worker cannot silently corrupt state.
--
-- Conventions:
--   * All timestamps are INTEGER unix seconds (UTC).
--   * Booleans are INTEGER 0/1 with CHECK constraints.
--   * `usage_ledger`, `entitlement_events` and `audit_events` are append-only,
--     enforced by triggers below. There is deliberately no delete endpoint.

-- ---------------------------------------------------------------------------
-- Identity
-- ---------------------------------------------------------------------------
CREATE TABLE users (
  id              TEXT    PRIMARY KEY,
  apple_sub       TEXT    NOT NULL UNIQUE,
  email           TEXT,
  role            TEXT    NOT NULL DEFAULT 'user'
                    CHECK (role IN ('user', 'support', 'admin')),
  disabled_at     INTEGER,
  created_at      INTEGER NOT NULL,
  updated_at      INTEGER NOT NULL,
  CHECK (length(apple_sub) BETWEEN 1 AND 255),
  CHECK (disabled_at IS NULL OR disabled_at >= created_at)
);

-- Refresh sessions. Only the SHA-256 hash of the refresh token is stored, so a
-- database disclosure does not yield usable credentials.
CREATE TABLE auth_sessions (
  id                  TEXT    PRIMARY KEY,
  user_id             TEXT    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  refresh_token_hash  TEXT    NOT NULL UNIQUE,
  device_label        TEXT,
  created_at          INTEGER NOT NULL,
  expires_at          INTEGER NOT NULL,
  last_used_at        INTEGER,
  revoked_at          INTEGER,
  CHECK (expires_at > created_at),
  CHECK (length(refresh_token_hash) = 64)
);

CREATE INDEX idx_auth_sessions_user ON auth_sessions (user_id, revoked_at);
CREATE INDEX idx_auth_sessions_expiry ON auth_sessions (expires_at);

-- ---------------------------------------------------------------------------
-- Billing linkage
-- ---------------------------------------------------------------------------
CREATE TABLE billing_customers (
  id                    TEXT    PRIMARY KEY,
  user_id               TEXT    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  provider              TEXT    NOT NULL CHECK (provider IN ('stripe', 'storekit')),
  provider_customer_id  TEXT    NOT NULL,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL,
  UNIQUE (provider, provider_customer_id),
  UNIQUE (user_id, provider)
);

-- ---------------------------------------------------------------------------
-- Entitlements
-- ---------------------------------------------------------------------------
-- Exactly one entitlement row per user. `status` is a soft state machine:
-- revocation and expiry are recorded, never deleted, so support can always
-- reconstruct why access was granted or withdrawn.
CREATE TABLE entitlements (
  id                     TEXT    PRIMARY KEY,
  user_id                TEXT    NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  plan_id                TEXT    NOT NULL,
  status                 TEXT    NOT NULL
                           CHECK (status IN ('none', 'trialing', 'active', 'grace',
                                             'past_due', 'revoked', 'expired')),
  source                 TEXT    NOT NULL CHECK (source IN ('stripe', 'storekit', 'manual')),
  source_reference       TEXT,
  current_period_start   INTEGER,
  current_period_end     INTEGER,
  cancel_at_period_end   INTEGER NOT NULL DEFAULT 0 CHECK (cancel_at_period_end IN (0, 1)),
  revoked_at             INTEGER,
  revocation_reason      TEXT,
  -- Monotonic counter used for optimistic concurrency and for ignoring
  -- webhook deliveries that arrive out of order.
  version                INTEGER NOT NULL DEFAULT 1 CHECK (version >= 1),
  source_event_at        INTEGER,
  created_at             INTEGER NOT NULL,
  updated_at             INTEGER NOT NULL,
  UNIQUE (source, source_reference),
  CHECK (current_period_end IS NULL OR current_period_start IS NULL
         OR current_period_end >= current_period_start),
  CHECK (status <> 'revoked' OR revoked_at IS NOT NULL)
);

CREATE INDEX idx_entitlements_status ON entitlements (status, current_period_end);

-- Append-only audit trail of every entitlement transition.
CREATE TABLE entitlement_events (
  id               TEXT    PRIMARY KEY,
  user_id          TEXT    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  from_status      TEXT    NOT NULL,
  to_status        TEXT    NOT NULL,
  source           TEXT    NOT NULL CHECK (source IN ('stripe', 'storekit', 'manual', 'system')),
  source_event_id  TEXT,
  reason           TEXT    NOT NULL,
  correlation_id   TEXT    NOT NULL,
  created_at       INTEGER NOT NULL
);

CREATE INDEX idx_entitlement_events_user ON entitlement_events (user_id, created_at);

-- ---------------------------------------------------------------------------
-- Webhook idempotency
-- ---------------------------------------------------------------------------
-- The UNIQUE(provider, event_id) constraint is the idempotency mechanism:
-- a duplicate delivery fails the INSERT and is acknowledged without reprocessing.
CREATE TABLE webhook_events (
  id              TEXT    PRIMARY KEY,
  provider        TEXT    NOT NULL CHECK (provider IN ('stripe', 'appstore')),
  event_id        TEXT    NOT NULL,
  event_type      TEXT    NOT NULL,
  status          TEXT    NOT NULL DEFAULT 'received'
                    CHECK (status IN ('received', 'processed', 'ignored', 'failed')),
  payload_digest  TEXT    NOT NULL,
  correlation_id  TEXT    NOT NULL,
  received_at     INTEGER NOT NULL,
  processed_at    INTEGER,
  failure_reason  TEXT,
  UNIQUE (provider, event_id)
);

CREATE INDEX idx_webhook_events_received ON webhook_events (received_at);

-- ---------------------------------------------------------------------------
-- Usage ledger
-- ---------------------------------------------------------------------------
-- Append-only. `units` is always computed server-side from the audio or the
-- upstream response; a client-supplied value is never trusted or persisted.
CREATE TABLE usage_ledger (
  id               TEXT    PRIMARY KEY,
  user_id          TEXT    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  idempotency_key  TEXT    NOT NULL,
  operation        TEXT    NOT NULL
                     CHECK (operation IN ('live_transcription', 'batch_transcription',
                                          'post_processing')),
  provider         TEXT    NOT NULL,
  model            TEXT    NOT NULL,
  unit_kind        TEXT    NOT NULL CHECK (unit_kind IN ('audio_seconds', 'tokens')),
  units            INTEGER NOT NULL CHECK (units >= 0),
  billing_period   TEXT    NOT NULL,
  correlation_id   TEXT    NOT NULL,
  created_at       INTEGER NOT NULL,
  UNIQUE (user_id, idempotency_key),
  CHECK (length(billing_period) = 7)
);

CREATE INDEX idx_usage_ledger_period ON usage_ledger (user_id, billing_period);

-- ---------------------------------------------------------------------------
-- Request idempotency
-- ---------------------------------------------------------------------------
-- Claimed *before* quota is reserved and before the vendor is called, so a
-- retried request cannot buy a second upstream call. `usage_ledger` cannot serve
-- this purpose: it is append-only and is only written once the work is done, by
-- which point the money has already been spent twice.
--
-- Deliberately stores no request or response content. An earlier draft kept the
-- first attempt's response body here so a client that lost it to a timeout could
-- get its transcript back; that made this table a store of dictated text, which
-- contradicts the promise that transcripts are never retained. A retry that
-- arrives after the work completed is told so and charged nothing, which costs
-- the user a re-dictation in a rare case and keeps the guarantee absolute.
--
-- `expires_at` bounds how long a key is remembered, as defence in depth. Keys
-- identify one logical *attempt* — the client mixes a per-attempt id into them,
-- so a second dictation of the same words is a different key and is processed
-- normally — but a key that lived for ever would still make the permanent
-- `usage_ledger` uniqueness reachable by an unlucky repeat. Expiry is applied on
-- read and on claim, so no scheduled job is required for correctness.
CREATE TABLE request_claims (
  id               TEXT    PRIMARY KEY,
  user_id          TEXT    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  idempotency_key  TEXT    NOT NULL,
  operation        TEXT    NOT NULL
                     CHECK (operation IN ('live_transcription', 'batch_transcription',
                                          'post_processing')),
  status           TEXT    NOT NULL DEFAULT 'in_flight'
                     CHECK (status IN ('in_flight', 'completed')),
  correlation_id   TEXT    NOT NULL,
  created_at       INTEGER NOT NULL,
  expires_at       INTEGER NOT NULL,
  completed_at     INTEGER,
  UNIQUE (user_id, idempotency_key)
);

CREATE INDEX idx_request_claims_created ON request_claims (created_at);

-- ---------------------------------------------------------------------------
-- General audit log
-- ---------------------------------------------------------------------------
-- Never contains audio, transcript text, tokens or secrets — only the shape of
-- what happened, keyed by correlation id.
CREATE TABLE audit_events (
  id              TEXT    PRIMARY KEY,
  user_id         TEXT    REFERENCES users(id) ON DELETE SET NULL,
  actor           TEXT    NOT NULL CHECK (actor IN ('user', 'system', 'webhook')),
  action          TEXT    NOT NULL,
  outcome         TEXT    NOT NULL CHECK (outcome IN ('allowed', 'denied', 'error')),
  detail          TEXT,
  correlation_id  TEXT    NOT NULL,
  created_at      INTEGER NOT NULL
);

CREATE INDEX idx_audit_events_user ON audit_events (user_id, created_at);

-- ---------------------------------------------------------------------------
-- Append-only enforcement
-- ---------------------------------------------------------------------------
CREATE TRIGGER usage_ledger_no_update
BEFORE UPDATE ON usage_ledger
BEGIN
  SELECT RAISE(ABORT, 'usage_ledger is append-only');
END;

CREATE TRIGGER usage_ledger_no_delete
BEFORE DELETE ON usage_ledger
BEGIN
  SELECT RAISE(ABORT, 'usage_ledger is append-only');
END;

CREATE TRIGGER entitlement_events_no_update
BEFORE UPDATE ON entitlement_events
BEGIN
  SELECT RAISE(ABORT, 'entitlement_events is append-only');
END;

CREATE TRIGGER entitlement_events_no_delete
BEFORE DELETE ON entitlement_events
BEGIN
  SELECT RAISE(ABORT, 'entitlement_events is append-only');
END;

CREATE TRIGGER audit_events_no_update
BEFORE UPDATE ON audit_events
BEGIN
  SELECT RAISE(ABORT, 'audit_events is append-only');
END;

CREATE TRIGGER audit_events_no_delete
BEFORE DELETE ON audit_events
BEGIN
  SELECT RAISE(ABORT, 'audit_events is append-only');
END;
