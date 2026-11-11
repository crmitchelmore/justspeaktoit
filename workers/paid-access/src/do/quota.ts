/**
 * Per-user quota and concurrency enforcement.
 *
 * One Durable Object instance per user gives us a single-threaded serialisation
 * point, which is what makes reserve/finalise correct: two devices starting a
 * long recording at the same moment cannot both pass a check-then-act race, and
 * unconsumed permits expire safely. A possibly dispatched batch/post operation
 * retains its allowance hold until a measured result is known.
 *
 * Quota is never trusted from the client. Callers reserve an upper bound before
 * work starts and finalise with the *measured* amount afterwards; the delta is
 * released back.
 *
 * Every method has the same shape: load through `QuotaStore`, decide with the
 * pure functions in quota-accounting.ts and quota-policy.ts, then persist the
 * decision in one write.
 */

import { Repository } from '../data/repository.js';
import type { Env } from '../env.js';
import {
  ZERO_LIMITS, admitLease, admitOperation, chargeExpiredLeases, commitUnits, quotaSnapshot, settleLease,
  sweepReservations, type QuotaLimits, type QuotaSnapshot, type QuotaUnitKind, type Reservation,
} from './quota-accounting.js';
import { isExpiredOperation, operationStep, reconcileStep, type ReconcileResult } from './quota-policy.js';
import { QuotaStore, pendingMarkerSeconds } from './quota-store.js';
import { pendingKey, type SettlementReceipt, type SettlementRequest, type SettlementResponse } from './settlement.js';

export type { QuotaLimits, QuotaSnapshot, QuotaUnitKind } from './quota-accounting.js';

export interface ReserveRequest {
  readonly kind: 'reserve';
  readonly period: string;
  readonly unitKind: QuotaUnitKind;
  readonly units: number;
  readonly limits: QuotaLimits;
  readonly countsAsSession: boolean;
  readonly nowSeconds: number;
}

export interface FinaliseRequest {
  readonly kind: 'finalise';
  readonly reservationId: string;
  readonly actualUnits: number;
  readonly nowSeconds: number;
}

export interface ReleaseRequest {
  readonly kind: 'release';
  readonly reservationId: string;
  readonly nowSeconds: number;
}

export interface StatusRequest {
  readonly kind: 'status';
  readonly period: string;
  readonly limits: QuotaLimits;
  readonly nowSeconds: number;
}

export type QuotaRequest = ReserveRequest | FinaliseRequest | ReleaseRequest | StatusRequest;

export type QuotaResponse =
  | { readonly ok: true; readonly reservationId: string; readonly snapshot: QuotaSnapshot }
  | { readonly ok: true; readonly snapshot: QuotaSnapshot }
  | { readonly ok: false; readonly reason: 'quota_exceeded' | 'too_many_sessions'; readonly snapshot: QuotaSnapshot };

export class QuotaDurableObject implements DurableObject {
  private readonly state: DurableObjectState;
  private readonly store: QuotaStore;

  constructor(state: DurableObjectState, private readonly env: Env) {
    this.state = state;
    this.store = new QuotaStore(state.storage);
  }

  async fetch(request: Request): Promise<Response> {
    if (request.method !== 'POST') {
      return new Response('Method Not Allowed', { status: 405 });
    }
    let body: QuotaRequest | SettlementRequest;
    try {
      body = (await request.json());
    } catch {
      return new Response('Bad Request', { status: 400 });
    }

    if (body.kind === 'operation_reconcile') {
      await this.reconcile(body.idempotencyKey);
      return Response.json(await this.state.blockConcurrencyWhile(async () => ({
        ok: true, receipt: await this.operationLookup(body.idempotencyKey, Math.floor(Date.now() / 1000)),
      })));
    }
    if (body.kind.startsWith('operation_')) {
      return Response.json(await this.state.blockConcurrencyWhile(() => this.operation(body as SettlementRequest)));
    }
    // `blockConcurrencyWhile` is what makes reserve/finalise atomic against
    // other requests for the same user.
    const response = await this.state.blockConcurrencyWhile(() => this.handle(body as QuotaRequest));
    return Response.json(response);
  }

  private async handle(request: QuotaRequest): Promise<QuotaResponse> {
    switch (request.kind) {
      case 'reserve':
        return this.reserve(request);
      case 'finalise':
        return this.finalise(request);
      case 'release':
        return this.release(request);
      case 'status':
        return this.status(request);
    }
  }

  /**
   * Returns active reservations after sweeping expired ones: unused operation
   * permits are revoked, possibly dispatched ones stay held, and legacy live
   * leases are charged in full (see `sweepReservations`).
   */
  private async loadReservations(nowSeconds: number): Promise<Reservation[]> {
    const stored = await this.store.reservations();
    const receipts = await this.store.receipts(stored
      .filter((entry) => isExpiredOperation(entry, nowSeconds))
      .map((entry) => entry.operationKey as string));
    const { live, expired, receiptUpdates } = sweepReservations(stored, receipts, nowSeconds);
    if (receiptUpdates.length > 0) {
      await this.store.write({ receipts: receiptUpdates, reservations: live.concat(expired) });
    }
    if (expired.length > 0) {
      const periods = await this.store.periods(expired.map((entry) => entry.period));
      // Charge and retire leases in one durable write, retaining reconciliation
      // metadata so a late measured result can refund the unused reservation.
      await this.store.write({ periods: chargeExpiredLeases(periods, expired), reservations: live, expired });
    }
    return live;
  }

  private async reserve(request: ReserveRequest): Promise<QuotaResponse> {
    if (!Number.isFinite(request.units) || request.units < 0) {
      throw new Error('Reservation units must be a non-negative number');
    }
    // Reservations first: sweeping an expired lease commits it, and the period
    // must be read after that or the check would run against stale usage.
    const reservations = await this.loadReservations(request.nowSeconds);
    const period = await this.store.period(request.period);
    const admission = admitLease(request, period, reservations, crypto.randomUUID());
    if (!admission.ok) return admission;
    await this.store.write({ periods: [period], latestPeriod: period.period, reservations: admission.reservations });
    return {
      ok: true,
      reservationId: admission.reservation.id,
      snapshot: quotaSnapshot(period, admission.reservations, request.limits),
    };
  }

  private async finalise(request: FinaliseRequest): Promise<QuotaResponse> {
    if (!Number.isSafeInteger(request.actualUnits) || request.actualUnits < 0) {
      throw new Error('Invalid measured usage');
    }
    const reservations = await this.loadReservations(request.nowSeconds);
    const expired = await this.store.expiredReservation(request.reservationId);
    const live = reservations.find((entry) => entry.id === request.reservationId);
    const reservation = live ?? expired ?? undefined;
    if (reservation === undefined) {
      return { ok: true, snapshot: quotaSnapshot(await this.store.latestPeriod(), reservations, ZERO_LIMITS) };
    }
    if (reservation.operationKey !== undefined) throw new Error('Owned operation requires settlement');
    const remaining = reservations.filter((entry) => entry.id !== request.reservationId);
    const period = settleLease(
      await this.store.period(reservation.period), reservation, live !== undefined, request.actualUnits,
    );
    await this.store.write({ periods: [period], reservations: remaining, retiredExpired: [request.reservationId] });
    return { ok: true, snapshot: quotaSnapshot(period, remaining, ZERO_LIMITS) };
  }

  private async release(request: ReleaseRequest): Promise<QuotaResponse> {
    const reservations = await this.loadReservations(request.nowSeconds);
    if (reservations.some((entry) => entry.id === request.reservationId && entry.operationKey !== undefined)) {
      throw new Error('Owned operation requires cancellation');
    }
    const remaining = reservations.filter((entry) => entry.id !== request.reservationId);
    await this.store.write({ reservations: remaining });
    return { ok: true, snapshot: quotaSnapshot(await this.store.latestPeriod(), remaining, ZERO_LIMITS) };
  }

  private async status(request: StatusRequest): Promise<QuotaResponse> {
    // Sweep before reading so expired permits and retained unknown holds are
    // reflected alongside the unchanged legacy live-expiry accounting.
    const reservations = await this.loadReservations(request.nowSeconds);
    const period = await this.store.period(request.period);
    return { ok: true, snapshot: quotaSnapshot(period, reservations, request.limits) };
  }

  private async operationLookup(key: string, now: number): Promise<SettlementReceipt | null> {
    await this.loadReservations(now);
    return (await this.store.receipt(key)) ?? null;
  }

  private async operation(request: SettlementRequest): Promise<SettlementResponse> {
    if (request.kind === 'operation_reconcile') throw new Error('Reconciliation must run outside the storage gate');
    const receipt = await this.operationLookup(request.idempotencyKey, request.nowSeconds);
    if (request.kind === 'operation_lookup') return { ok: true, receipt };
    if (request.kind === 'operation_reserve') {
      if (receipt !== null) return { ok: false, receipt, reason: 'conflict' };
      if (!/^[A-Za-z0-9_-]{16,128}$/.test(request.idempotencyKey)
        || !Number.isSafeInteger(request.units) || request.units < 0) throw new Error('Invalid admission');
      const reservations = await this.loadReservations(request.nowSeconds);
      const period = await this.store.period(request.period);
      const admission = admitOperation(request, period, reservations,
        { reservationId: crypto.randomUUID(), ledgerEntryId: crypto.randomUUID() });
      if (!admission.ok) return { ok: false, receipt: null, reason: 'quota_exceeded' };
      await this.store.write({ receipts: [admission.receipt], periods: [period], latestPeriod: period.period,
        reservations: [...reservations, admission.reservation] });
      return { ok: true, receipt: admission.receipt };
    }
    const decision = operationStep(receipt, request);
    if (decision.kind === 'refuse') return { ok: decision.ok, receipt, reason: 'conflict' };
    const next = decision.receipt;
    if (decision.effect === 'none') {
      await this.store.write({ receipts: [next] });
      return { ok: true, receipt: next };
    }
    const remaining = (await this.loadReservations(request.nowSeconds))
      .filter((entry) => entry.id !== next.reservationId);
    if (decision.effect === 'release_hold') {
      await this.store.write({ receipts: [next], reservations: remaining });
      return { ok: true, receipt: next };
    }
    const period = commitUnits(await this.store.period(next.billingPeriod), next.unitKind, next.actualUnits!);
    // Retry is installed before the durable measurement; an extra empty alarm is harmless.
    await this.store.ensureAlarm(next.nextReconcileAt!);
    await this.store.write({ receipts: [next], pending: [next], periods: [period], reservations: remaining });
    return { ok: true, receipt: next };
  }

  private async reconcile(key: string): Promise<void> {
    const receipt = await this.state.blockConcurrencyWhile(() => this.store.receipt(key));
    if (receipt?.phase !== 'ledger_pending' || receipt.lastFailure === 'ledger_conflict') return;
    let result: ReconcileResult;
    try {
      result = await new Repository(this.env.DB).usage.reconcileUsage({ ledgerEntryId: receipt.ledgerEntryId,
        userId: receipt.userId, idempotencyKey: receipt.idempotencyKey, operation: receipt.operation,
        provider: receipt.provider, model: receipt.model, unitKind: receipt.unitKind,
        units: receipt.actualUnits!, billingPeriod: receipt.billingPeriod,
        correlationId: receipt.correlationId, measuredAt: receipt.measuredAt! });
    } catch { result = 'unavailable'; }
    await this.state.blockConcurrencyWhile(async () => {
      const current = await this.store.receipt(key);
      if (current?.phase !== 'ledger_pending' || current.revision !== receipt.revision) return;
      const next = reconcileStep(current, result, Math.floor(Date.now() / 1000));
      if (next.nextReconcileAt !== undefined) await this.store.ensureAlarm(next.nextReconcileAt);
      await this.store.write({ receipts: [next], pending: next.nextReconcileAt === undefined ? [] : [next] });
      if (pendingKey(receipt) !== pendingKey(next)) await this.store.deletePendingMarker(pendingKey(receipt));
    });
    // Claims are only a projection. Their failure cannot undo durable settlement.
    if (result === 'matched') {
      await new Repository(this.env.DB).usage.completeRequestClaim({ userId: receipt.userId,
        idempotencyKey: key, nowSeconds: Math.floor(Date.now() / 1000) }).catch(() => undefined);
    }
  }

  async alarm(): Promise<void> {
    for (const [marker, key] of await this.store.pendingMarkers(25)) {
      const receipt = await this.store.receipt(key);
      if (receipt?.phase !== 'ledger_pending' || receipt.nextReconcileAt === undefined
        || pendingKey(receipt) !== marker) {
        await this.store.deletePendingMarker(marker);
      } else if (receipt.nextReconcileAt <= Math.floor(Date.now() / 1000)) {
        await this.reconcile(key);
      }
    }
    await this.state.blockConcurrencyWhile(async () => {
      const first = await this.store.pendingMarkers(1);
      const marker = first.keys().next().value as string | undefined;
      if (marker !== undefined) await this.store.ensureAlarm(pendingMarkerSeconds(marker));
      // Do not delete a different request's newly installed alarm.
    });
  }
}
