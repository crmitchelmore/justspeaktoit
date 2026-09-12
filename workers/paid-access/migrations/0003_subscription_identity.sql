-- Preserve each verified purchase independently; account access is derived.
CREATE TABLE subscription_states (
  id                     TEXT    PRIMARY KEY,
  user_id                TEXT    NOT NULL REFERENCES users(id) ON DELETE CASCADE,
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
CREATE UNIQUE INDEX idx_subscription_identity
  ON subscription_states (user_id, source, COALESCE(source_reference, ''));
INSERT INTO subscription_states SELECT * FROM entitlements;
CREATE TRIGGER subscription_states_no_delete BEFORE DELETE ON subscription_states
BEGIN SELECT RAISE(ABORT, 'subscription history is append-only'); END;
