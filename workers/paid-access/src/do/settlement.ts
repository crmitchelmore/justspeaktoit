/** Metadata-only state owned by the existing per-user quota object. */
import type { PaidOperationName } from '../data/repository.js';
import type { QuotaLimits, QuotaUnitKind } from './quota.js';

export type SettlementPhase = 'reserved' | 'provider_started' | 'outcome_unknown'
  | 'ledger_pending' | 'settled' | 'not_started';

export interface SettlementReceipt {
  schemaVersion: 1;
  userId: string;
  idempotencyKey: string;
  operation: PaidOperationName;
  reservationId: string;
  ledgerEntryId: string;
  ownerId: string;
  provider: string;
  model: string;
  unitKind: QuotaUnitKind;
  billingPeriod: string;
  reservedUnits: number;
  phase: SettlementPhase;
  revision: number;
  createdAt: number;
  updatedAt: number;
  expiresAt: number;
  correlationId: string;
  actualUnits?: number;
  measuredAt?: number;
  nextReconcileAt?: number;
  reconcileAttempts: number;
  lastFailure?: 'ledger_unavailable' | 'ledger_conflict';
}

export interface OperationAdmission {
  userId: string;
  idempotencyKey: string;
  operation: PaidOperationName;
  ownerId: string;
  provider: string;
  model: string;
  unitKind: QuotaUnitKind;
  period: string;
  units: number;
  correlationId: string;
  nowSeconds: number;
}

export interface OwnedOperation {
  idempotencyKey: string;
  ownerId: string;
  revision: number;
  nowSeconds: number;
}

export type SettlementRequest =
  | { kind: 'operation_lookup'; idempotencyKey: string; nowSeconds: number }
  | ({ kind: 'operation_reserve'; limits: QuotaLimits } & OperationAdmission)
  | ({ kind: 'operation_start' | 'operation_cancel' | 'operation_unknown' } & OwnedOperation)
  | ({ kind: 'operation_measure'; actualUnits: number; measuredAt: number } & OwnedOperation)
  | { kind: 'operation_reconcile'; idempotencyKey: string };

export type SettlementResponse = {
  ok: boolean;
  receipt: SettlementReceipt | null;
  reason?: 'quota_exceeded' | 'conflict';
};

export const RECEIPT_PREFIX = 'operation:';
export const PENDING_PREFIX = 'settlement_pending:';
export function receiptKey(key: string): string { return RECEIPT_PREFIX + key; }
export function pendingKey(receipt: SettlementReceipt): string {
  return PENDING_PREFIX + String(receipt.nextReconcileAt).padStart(16, '0') + ':' + receipt.ledgerEntryId;
}
