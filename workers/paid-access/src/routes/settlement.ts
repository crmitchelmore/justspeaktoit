import { ApiError, type ErrorCode } from '../http.js';
import type { AuthenticatedContext } from '../context.js';
import type { PaidOperationName } from '../data/repository.js';
import type { SettlementReceipt, OperationAdmission } from '../do/settlement.js';

export const SETTLEMENT_HEADER = 'x-paid-settlement-contract';
export const SETTLEMENT_VERSION = '1';

/** Older clients interpret unknown error codes as permission to spend again. */
export function operationError(request: Request, code: ErrorCode = 'outcome_unknown'): ApiError {
  return new ApiError(request.headers.get(SETTLEMENT_HEADER) === SETTLEMENT_VERSION ? code : 'already_processed',
    'The operation outcome could not be confirmed. No additional provider request was started.');
}

export function retainedOperation(request: Request, receipt: SettlementReceipt): ApiError {
  const code: ErrorCode = receipt.phase === 'settled' ? 'already_processed'
    : receipt.phase === 'not_started' ? 'request_not_started'
    : receipt.phase === 'ledger_pending' ? 'settlement_pending'
    : receipt.phase === 'outcome_unknown' ? 'outcome_unknown' : 'request_in_progress';
  // A revoked permit is durable proof of no dispatch; old clients may safely fall back.
  if (code === 'request_not_started') return new ApiError(code, 'This operation was not started');
  return operationError(request, code);
}

/** Establish retained state before any version/policy refusal can permit fallback. */
export async function claimOperation(request: Request, context: AuthenticatedContext,
  key: string, operation: PaidOperationName): Promise<void> {
  const receipt = await context.quota.operationReceipt(context.session.userId, key, context.nowSeconds);
  if (receipt !== null) {
    if (receipt.operation !== operation) throw operationError(request, 'conflict');
    throw retainedOperation(request, receipt);
  }
  const existing = await context.repository.claimRequest({ userId: context.session.userId,
    idempotencyKey: key, operation, correlationId: context.correlationId, nowSeconds: context.nowSeconds });
  if (existing !== null) throw operationError(request, existing.operation !== operation ? 'conflict'
    : existing.status === 'completed' ? 'already_processed' : 'request_in_progress');
}

/** The returned permit is consumed once. A lost acknowledgement is never retried as dispatch. */
export async function runOperation(
  request: Request, context: AuthenticatedContext, input: Omit<OperationAdmission, 'ownerId' | 'userId' | 'nowSeconds' | 'correlationId'>,
  work: () => Promise<{ payload: Record<string, unknown>; units: number | null }>,
): Promise<Record<string, unknown>> {
  const userId = context.session.userId;
  const ownerId = crypto.randomUUID();
  const now = (): number => Math.floor(Date.now() / 1000);
  let receipt: SettlementReceipt | null = null;
  try {
    const reserved = await context.quota.reserveOperation({ ...input, ownerId, userId,
      nowSeconds: now(), correlationId: context.correlationId });
    if (!reserved.ok) {
      if (reserved.receipt !== null) throw retainedOperation(request, reserved.receipt);
      if (reserved.reason === 'quota_exceeded') throw new ApiError('quota_exceeded', 'Monthly allowance is occupied');
      throw operationError(request);
    }
    receipt = reserved.receipt;
    if (receipt === null) throw operationError(request);
    const started = await context.quota.operation(userId, { kind: 'operation_start',
      idempotencyKey: input.idempotencyKey, ownerId, revision: receipt.revision, nowSeconds: now() });
    if (!started.ok || started.receipt === null) {
      throw started.receipt === null ? operationError(request) : retainedOperation(request, started.receipt);
    }
    receipt = started.receipt;
    const result = await work();
    if (result.units === null) throw operationError(request);
    const measuredAt = now();
    // Only retry the same immutable measurement. The provider is never retried.
    for (let attempt = 0; attempt < 3; attempt += 1) {
      try {
        const current = await context.quota.operationReceipt(userId, input.idempotencyKey, now());
        if (current === null || current.ownerId !== ownerId) throw operationError(request);
        const measured = await context.quota.operation(userId, { kind: 'operation_measure',
          idempotencyKey: input.idempotencyKey, ownerId, revision: current.revision, nowSeconds: now(),
          actualUnits: result.units, measuredAt });
        if (measured.ok && measured.receipt !== null
          && ['ledger_pending', 'settled'].includes(measured.receipt.phase)
          && measured.receipt.actualUnits === result.units && measured.receipt.measuredAt === measuredAt) {
          // The durable receipt already guarantees recovery; projection failure cannot lose the result.
          await context.quota.operation(userId, { kind: 'operation_reconcile',
            idempotencyKey: input.idempotencyKey }).catch(() => undefined);
          return result.payload;
        }
      } catch { /* A lost measurement acknowledgement is resolved by this bounded same-owner read/retry. */ }
    }
    throw operationError(request, 'settlement_pending');
  } catch (error) {
    // A quota denial happened before a permit existed. The caller's original claim can be released.
    if (receipt === null && error instanceof ApiError && error.code === 'quota_exceeded') throw error;
    if (receipt !== null) {
      try {
        const current = await context.quota.operationReceipt(userId, input.idempotencyKey, now());
        if (current !== null && current.ownerId === ownerId && current.phase === 'provider_started') {
          await context.quota.operation(userId, { kind: 'operation_unknown', idempotencyKey: input.idempotencyKey,
            ownerId, revision: current.revision, nowSeconds: now() });
        }
      } catch { /* Retained started state/lease is fail-closed even when acknowledgement is unavailable. */ }
    }
    // A generic provider/storage exception is never permission for BYO spending.
    throw error instanceof ApiError && ['already_processed', 'request_in_progress', 'settlement_pending',
      'outcome_unknown', 'request_not_started'].includes(error.code) ? error : operationError(request);
  }
}
