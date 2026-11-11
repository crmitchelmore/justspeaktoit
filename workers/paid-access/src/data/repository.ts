/**
 * D1 access.
 *
 * All SQL lives here so the constraints in `migrations/` and the queries that
 * rely on them stay side by side. Two rules hold throughout:
 *
 *   1. Transactions are short. D1 batches are used for the few multi-statement
 *      writes that must land together; nothing holds a transaction open across
 *      an upstream provider call.
 *   2. Uniqueness is the idempotency mechanism. Duplicate webhook deliveries
 *      and duplicate usage writes are rejected by the database, not by a
 *      read-then-write race in application code.
 */

import { AuditRepository } from './audit.js';
import { EntitlementRepository } from './entitlements.js';
import { UsageRepository } from './usage.js';
import { UserRepository } from './users.js';

export type { UserRecord } from './users.js';
export type { PaidOperationName, RequestClaim, RequestClaimStatus } from './usage.js';
export { REQUEST_CLAIM_TTL_SECONDS } from './usage.js';
export { AuditRepository, EntitlementRepository, UsageRepository, UserRepository };

/**
 * One D1 binding, one repository per aggregate. Each multi-statement write
 * stays inside the repository that owns its tables, so splitting the module
 * never splits a batch.
 */
export class Repository {
  readonly users: UserRepository;
  readonly entitlements: EntitlementRepository;
  readonly usage: UsageRepository;
  readonly audit: AuditRepository;

  constructor(db: D1Database) {
    this.users = new UserRepository(db);
    this.entitlements = new EntitlementRepository(db);
    this.usage = new UsageRepository(db);
    this.audit = new AuditRepository(db);
  }
}
