/**
 * Pure allowance accounting for the per-user quota object.
 *
 * `QuotaDurableObject` loads state through `QuotaStore`, asks these functions
 * (and the settlement transitions in quota-policy.ts) what the state becomes,
 * then persists the answer. Nothing here reads storage or the clock.
 */

import { expiryDecision } from './quota-policy.js';
import type { OperationAdmission, SettlementReceipt } from './settlement.js';

export interface QuotaLimits {
  readonly monthlyAudioSeconds: number;
  readonly monthlyTokens: number;
  readonly maxConcurrentSessions: number;
  /** Dispatch-permit lease; expiry does not release possibly dispatched operation holds. */
  readonly leaseSeconds: number;
}

export type QuotaUnitKind = 'audio_seconds' | 'tokens';

export interface QuotaSnapshot {
  readonly period: string;
  readonly audioSecondsUsed: number;
  readonly audioSecondsLimit: number;
  readonly tokensUsed: number;
  readonly tokensLimit: number;
  readonly activeSessions: number;
  readonly maxConcurrentSessions: number;
  readonly audioSecondsMeasured?: number;
  readonly audioSecondsHeld: number;
  readonly tokensMeasured?: number;
  readonly tokensHeld: number;
}

/** An allowance hold: a live lease, or the hold of an owned operation. */
export interface Reservation {
  readonly id: string;
  readonly period: string;
  readonly unitKind: QuotaUnitKind;
  readonly units: number;
  readonly countsAsSession: boolean;
  readonly expiresAt: number;
  readonly operationKey?: string;
}

/** Committed usage for one billing period. */
export interface PeriodState {
  period: string;
  audioSecondsCommitted: number;
  tokensCommitted: number;
  measuredKnown?: boolean;
}

/**
 * Limits are supplied by the caller on requests that need to enforce them.
 * Finalise and release only report usage, so they use a zero-limit placeholder
 * rather than pretending to know the plan.
 */
export const ZERO_LIMITS: QuotaLimits = {
  monthlyAudioSeconds: 0,
  monthlyTokens: 0,
  maxConcurrentSessions: 0,
  leaseSeconds: 0,
};

export function emptyPeriod(period: string): PeriodState {
  return { period, audioSecondsCommitted: 0, tokensCommitted: 0, measuredKnown: true };
}

export function quotaSnapshot(
  period: PeriodState,
  reservations: readonly Reservation[],
  limits: QuotaLimits,
): QuotaSnapshot {
  // Only this period's reservations count towards this period's allowance; a
  // lease still open across a month boundary belongs to the month it started in.
  const current = reservations.filter((entry) => entry.period === period.period);
  const reservedAudio = current
    .filter((entry) => entry.unitKind === 'audio_seconds')
    .reduce((total, entry) => total + entry.units, 0);
  const reservedTokens = current
    .filter((entry) => entry.unitKind === 'tokens')
    .reduce((total, entry) => total + entry.units, 0);
  return {
    period: period.period,
    audioSecondsUsed: period.audioSecondsCommitted + reservedAudio,
    audioSecondsLimit: limits.monthlyAudioSeconds,
    tokensUsed: period.tokensCommitted + reservedTokens,
    audioSecondsMeasured: period.measuredKnown === true ? period.audioSecondsCommitted : undefined,
    audioSecondsHeld: reservedAudio,
    tokensMeasured: period.measuredKnown === true ? period.tokensCommitted : undefined,
    tokensHeld: reservedTokens,
    tokensLimit: limits.monthlyTokens,
    // Concurrency is a live-now property, so it counts every open lease
    // regardless of which billing period it was taken in.
    activeSessions: reservations.filter((entry) => entry.countsAsSession).length,
    maxConcurrentSessions: limits.maxConcurrentSessions,
  };
}

/** Adds measured or charged units to a period's committed usage. */
export function commitUnits(period: PeriodState, unitKind: QuotaUnitKind, units: number): PeriodState {
  return unitKind === 'audio_seconds'
    ? { ...period, audioSecondsCommitted: period.audioSecondsCommitted + units }
    : { ...period, tokensCommitted: period.tokensCommitted + units };
}

/** The holds left after an expiry sweep, and what the sweep must write. */
export interface ReservationSweep {
  readonly live: Reservation[];
  /** Legacy leases that expired unfinalised and are charged in full. */
  readonly expired: Reservation[];
  /** Operation receipts the sweep revoked or marked unknown. */
  readonly receiptUpdates: SettlementReceipt[];
}

/**
 * Applies `expiryDecision` to every stored hold.
 *
 * Keyed operations revoke unused permits or retain unknown holds. A legacy
 * live lease expires only when nothing finalised or released it — a crashed
 * Worker, a device that vanished mid-session. The reserved amount was the
 * agreed upper bound for that work, so committing it is the only outcome that
 * cannot hand the usage away for free; anything genuinely smaller would have
 * arrived through `finalise` before the lease ran out.
 *
 * @param receipts the receipt of each expired operation, by idempotency key.
 */
export function sweepReservations(
  stored: readonly Reservation[],
  receipts: ReadonlyMap<string, SettlementReceipt>,
  nowSeconds: number,
): ReservationSweep {
  const live: Reservation[] = [];
  const expired: Reservation[] = [];
  const receiptUpdates: SettlementReceipt[] = [];
  for (const reservation of stored) {
    const receipt = reservation.operationKey === undefined ? undefined : receipts.get(reservation.operationKey);
    const decision = expiryDecision(reservation, nowSeconds, receipt);
    if (decision.kind === 'charge') expired.push(reservation);
    else if (decision.kind !== 'revoke') live.push(reservation);
    if ((decision.kind === 'revoke' || decision.kind === 'retain') && decision.receipt !== undefined) {
      receiptUpdates.push(decision.receipt);
    }
  }
  return { live, expired, receiptUpdates };
}

/**
 * Charges expired leases in full to their own periods. Measured totals become
 * unknown until a late finalise refunds the unused part.
 */
export function chargeExpiredLeases(
  periods: ReadonlyMap<string, PeriodState>,
  expired: readonly Reservation[],
): PeriodState[] {
  const charged = new Map(periods);
  for (const reservation of expired) {
    const period = charged.get(reservation.period) ?? emptyPeriod(reservation.period);
    charged.set(reservation.period, {
      ...commitUnits(period, reservation.unitKind, reservation.units), measuredKnown: false,
    });
  }
  return [...charged.values()];
}

export interface LeaseRequest {
  readonly period: string;
  readonly unitKind: QuotaUnitKind;
  readonly units: number;
  readonly limits: QuotaLimits;
  readonly countsAsSession: boolean;
  readonly nowSeconds: number;
}

export type LeaseAdmission =
  | { readonly ok: false; readonly reason: 'quota_exceeded' | 'too_many_sessions'; readonly snapshot: QuotaSnapshot }
  | { readonly ok: true; readonly reservation: Reservation; readonly reservations: Reservation[] };

/** Admits a live lease against the concurrency limit and the monthly allowance. */
export function admitLease(
  request: LeaseRequest,
  period: PeriodState,
  reservations: readonly Reservation[],
  reservationId: string,
): LeaseAdmission {
  const before = quotaSnapshot(period, reservations, request.limits);
  if (request.countsAsSession && before.activeSessions >= request.limits.maxConcurrentSessions) {
    return { ok: false, reason: 'too_many_sessions', snapshot: before };
  }
  const projectedAudio = before.audioSecondsUsed + (request.unitKind === 'audio_seconds' ? request.units : 0);
  const projectedTokens = before.tokensUsed + (request.unitKind === 'tokens' ? request.units : 0);
  if (projectedAudio > request.limits.monthlyAudioSeconds || projectedTokens > request.limits.monthlyTokens) {
    return { ok: false, reason: 'quota_exceeded', snapshot: before };
  }
  const reservation: Reservation = {
    id: reservationId,
    period: request.period,
    unitKind: request.unitKind,
    units: Math.ceil(request.units),
    countsAsSession: request.countsAsSession,
    expiresAt: request.nowSeconds + request.limits.leaseSeconds,
  };
  return { ok: true, reservation, reservations: [...reservations, reservation] };
}

/**
 * Settles a lease with its measured units. A live lease commits what was
 * charged; an expired one was already charged in full, so it commits only the
 * (negative) difference.
 */
export function settleLease(
  period: PeriodState,
  reservation: Reservation,
  wasLive: boolean,
  actualUnits: number,
): PeriodState {
  // Only trusted Worker code can settle. Keep actual token overruns visible;
  // audio remains capped by the server-enforced session duration.
  const charged = reservation.unitKind === 'tokens' ? actualUnits : Math.min(actualUnits, reservation.units);
  return commitUnits(period, reservation.unitKind, charged - (wasLive ? 0 : reservation.units));
}

export type OperationAdmissionDecision =
  | { readonly ok: false }
  | { readonly ok: true; readonly receipt: SettlementReceipt; readonly reservation: Reservation };

/** Admits an owned operation's hold and builds its first receipt. */
export function admitOperation(
  request: OperationAdmission & { readonly limits: QuotaLimits },
  period: PeriodState,
  reservations: readonly Reservation[],
  ids: { readonly reservationId: string; readonly ledgerEntryId: string },
): OperationAdmissionDecision {
  const snapshot = quotaSnapshot(period, reservations, request.limits);
  const occupied = request.unitKind === 'tokens' ? snapshot.tokensUsed : snapshot.audioSecondsUsed;
  const limit = request.unitKind === 'tokens' ? request.limits.monthlyTokens : request.limits.monthlyAudioSeconds;
  if (occupied + request.units > limit) return { ok: false };
  const receipt: SettlementReceipt = {
    schemaVersion: 1, userId: request.userId, idempotencyKey: request.idempotencyKey,
    operation: request.operation, reservationId: ids.reservationId, ledgerEntryId: ids.ledgerEntryId,
    ownerId: request.ownerId, provider: request.provider, model: request.model, unitKind: request.unitKind,
    billingPeriod: request.period, reservedUnits: request.units, phase: 'reserved', revision: 1,
    createdAt: request.nowSeconds, updatedAt: request.nowSeconds,
    expiresAt: request.nowSeconds + request.limits.leaseSeconds,
    correlationId: request.correlationId, reconcileAttempts: 0,
  };
  const reservation: Reservation = {
    id: receipt.reservationId, period: receipt.billingPeriod, unitKind: receipt.unitKind,
    units: receipt.reservedUnits, countsAsSession: false, expiresAt: receipt.expiresAt,
    operationKey: receipt.idempotencyKey,
  };
  return { ok: true, receipt, reservation };
}
