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
 */

import { Repository } from '../data/repository.js';
import type { Env } from '../env.js';
import {
  PENDING_PREFIX, receiptKey, pendingKey,
  type SettlementReceipt, type SettlementRequest, type SettlementResponse,
} from './settlement.js';

export interface QuotaLimits {
  readonly monthlyAudioSeconds: number;
  readonly monthlyTokens: number;
  readonly maxConcurrentSessions: number;
  /** Dispatch-permit lease; expiry does not release possibly dispatched operation holds. */
  readonly leaseSeconds: number;
}

export type QuotaUnitKind = 'audio_seconds' | 'tokens';

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

export type QuotaResponse =
  | { readonly ok: true; readonly reservationId: string; readonly snapshot: QuotaSnapshot }
  | { readonly ok: true; readonly snapshot: QuotaSnapshot }
  | { readonly ok: false; readonly reason: 'quota_exceeded' | 'too_many_sessions'; readonly snapshot: QuotaSnapshot };

interface Reservation {
  readonly id: string;
  readonly period: string;
  readonly unitKind: QuotaUnitKind;
  readonly units: number;
  readonly countsAsSession: boolean;
  readonly expiresAt: number;
  readonly operationKey?: string;
}

interface PeriodState {
  period: string;
  audioSecondsCommitted: number;
  tokensCommitted: number;
  measuredKnown?: boolean;
}

/**
 * Committed usage is stored one record per billing period.
 *
 * A single shared record cannot express "finalise a reservation taken last
 * month": the write would have to name one period, and naming the reservation's
 * period would overwrite — and so zero — the period that is currently being
 * metered. Keying by period lets a late finalise land where it belongs.
 */
const PERIOD_KEY_PREFIX = 'period:';
/** Pre-per-period-key storage layout; read once so no usage is lost on upgrade. */
const LEGACY_PERIOD_KEY = 'period';
/** The most recent period this user was seen in, used only for reporting. */
const LATEST_PERIOD_KEY = 'latest_period';
const RESERVATIONS_KEY = 'reservations';
const EXPIRED_PREFIX = 'expired:';

export class QuotaDurableObject implements DurableObject {
  private readonly state: DurableObjectState;

  constructor(state: DurableObjectState, private readonly env: Env) {
    this.state = state;
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

  private static periodKey(period: string): string {
    return `${PERIOD_KEY_PREFIX}${period}`;
  }

  private async loadPeriod(period: string): Promise<PeriodState> {
    const stored = await this.state.storage.get<PeriodState>(QuotaDurableObject.periodKey(period));
    if (stored !== undefined && stored.period === period) {
      return stored;
    }
    const legacy = await this.state.storage.get<PeriodState>(LEGACY_PERIOD_KEY);
    if (legacy !== undefined && legacy.period === period) {
      return legacy;
    }
    // A new billing period starts at zero; the ledger in D1 remains the durable
    // record of what came before.
    return { period, audioSecondsCommitted: 0, tokensCommitted: 0, measuredKnown: true };
  }

  /**
   * Returns active reservations, retaining unknown keyed operation holds.
   *
   * Keyed operations revoke unused permits or retain unknown holds. The legacy
   * live reservation policy below remains unchanged:
   * a lease expires only when nothing finalised or released it — a crashed
   * Worker, a device that vanished mid-session. The reserved amount was the
   * agreed upper bound for that work, so committing it is the only outcome that
   * cannot hand the usage away for free; anything genuinely smaller would have
   * arrived through `finalise` before the lease ran out.
   */
  private async loadReservations(nowSeconds: number): Promise<Reservation[]> {
    const stored = (await this.state.storage.get<Reservation[]>(RESERVATIONS_KEY)) ?? [];
    const live: Reservation[] = [];
    const expired: Reservation[] = [];
    const receiptUpdates: Record<string, SettlementReceipt> = {};
    for (const reservation of stored) {
      if (reservation.operationKey !== undefined && reservation.expiresAt <= nowSeconds) {
        const key = receiptKey(reservation.operationKey);
        const receipt = await this.state.storage.get<SettlementReceipt>(key);
        if (receipt?.phase === 'reserved') {
          receiptUpdates[key] = { ...receipt, phase: 'not_started', revision: receipt.revision + 1,
            updatedAt: nowSeconds };
          continue;
        }
        if (receipt?.phase === 'provider_started') {
          receiptUpdates[key] = { ...receipt, phase: 'outcome_unknown', revision: receipt.revision + 1,
            updatedAt: nowSeconds };
        }
        // A missing receipt is not proof of unused quota: keep the hold fail-closed.
        live.push(reservation);
      } else {
        (reservation.expiresAt > nowSeconds ? live : expired).push(reservation);
      }
    }
    if (Object.keys(receiptUpdates).length > 0) {
      await this.state.storage.put({ ...receiptUpdates, [RESERVATIONS_KEY]: live.concat(expired) });
    }
    if (expired.length > 0) {
      const periods: Record<string, PeriodState> = {};
      for (const reservation of expired) {
        const key = QuotaDurableObject.periodKey(reservation.period);
        const period = periods[key] ?? await this.loadPeriod(reservation.period);
        period.measuredKnown = false;
        if (reservation.unitKind === 'audio_seconds') period.audioSecondsCommitted += reservation.units;
        else period.tokensCommitted += reservation.units;
        periods[key] = period;
      }
      // Charge and retire leases in one durable write, retaining reconciliation
      // metadata so a late measured result can refund the unused reservation.
      await this.state.storage.put({ ...periods, [RESERVATIONS_KEY]: live,
        ...Object.fromEntries(expired.map((entry) => [EXPIRED_PREFIX + entry.id, entry])) });
    }
    return live;
  }

  /** The period to report on when the caller did not name one. */
  private async latestPeriod(): Promise<PeriodState> {
    const latest = await this.state.storage.get<string>(LATEST_PERIOD_KEY);
    if (latest !== undefined) return this.loadPeriod(latest);
    const legacy = await this.state.storage.get<PeriodState>(LEGACY_PERIOD_KEY);
    return legacy ?? { period: '1970-01', audioSecondsCommitted: 0, tokensCommitted: 0 };
  }

  private snapshot(
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

  private async reserve(request: ReserveRequest): Promise<QuotaResponse> {
    if (!Number.isFinite(request.units) || request.units < 0) {
      throw new Error('Reservation units must be a non-negative number');
    }
    // Reservations first: sweeping an expired lease commits it, and the period
    // must be read after that or the check would run against stale usage.
    const reservations = await this.loadReservations(request.nowSeconds);
    const period = await this.loadPeriod(request.period);
    const before = this.snapshot(period, reservations, request.limits);

    if (
      request.countsAsSession &&
      before.activeSessions >= request.limits.maxConcurrentSessions
    ) {
      return { ok: false, reason: 'too_many_sessions', snapshot: before };
    }

    const projectedAudio =
      before.audioSecondsUsed + (request.unitKind === 'audio_seconds' ? request.units : 0);
    const projectedTokens =
      before.tokensUsed + (request.unitKind === 'tokens' ? request.units : 0);

    if (
      projectedAudio > request.limits.monthlyAudioSeconds ||
      projectedTokens > request.limits.monthlyTokens
    ) {
      return { ok: false, reason: 'quota_exceeded', snapshot: before };
    }

    const reservation: Reservation = {
      id: crypto.randomUUID(),
      period: request.period,
      unitKind: request.unitKind,
      units: Math.ceil(request.units),
      countsAsSession: request.countsAsSession,
      expiresAt: request.nowSeconds + request.limits.leaseSeconds,
    };
    const next = [...reservations, reservation];
    await this.state.storage.put(QuotaDurableObject.periodKey(period.period), period);
    await this.state.storage.put(LATEST_PERIOD_KEY, period.period);
    await this.state.storage.put(RESERVATIONS_KEY, next);

    return {
      ok: true,
      reservationId: reservation.id,
      snapshot: this.snapshot(period, next, request.limits),
    };
  }

  private async finalise(request: FinaliseRequest): Promise<QuotaResponse> {
    if (!Number.isSafeInteger(request.actualUnits) || request.actualUnits < 0) {
      throw new Error('Invalid measured usage');
    }
    const reservations = await this.loadReservations(request.nowSeconds);
    const expired = await this.state.storage.get<Reservation | null>(EXPIRED_PREFIX + request.reservationId);
    const live = reservations.find((entry) => entry.id === request.reservationId);
    const reservation = live ?? expired ?? undefined;
    if (reservation === undefined) {
      return { ok: true, snapshot: this.snapshot(await this.latestPeriod(), reservations, ZERO_LIMITS) };
    }
    if (reservation.operationKey !== undefined) throw new Error('Owned operation requires settlement');
    const remaining = reservations.filter((entry) => entry.id !== request.reservationId);
    const period = await this.loadPeriod(reservation.period);
    // Only trusted Worker code can settle. Keep actual token overruns visible;
    // audio remains capped by the server-enforced session duration.
    const charged = reservation.unitKind === 'tokens'
      ? request.actualUnits : Math.min(request.actualUnits, reservation.units);
    const delta = charged - (live === undefined ? reservation.units : 0);
    if (reservation.unitKind === 'audio_seconds') period.audioSecondsCommitted += delta;
    else period.tokensCommitted += delta;
    await this.state.storage.put({
      [QuotaDurableObject.periodKey(period.period)]: period,
      [RESERVATIONS_KEY]: remaining,
      [EXPIRED_PREFIX + request.reservationId]: null,
    });
    return { ok: true, snapshot: this.snapshot(period, remaining, ZERO_LIMITS) };
  }

  private async release(request: ReleaseRequest): Promise<QuotaResponse> {
    const reservations = await this.loadReservations(request.nowSeconds);
    if (reservations.some((entry) => entry.id === request.reservationId && entry.operationKey !== undefined)) {
      throw new Error('Owned operation requires cancellation');
    }
    const remaining = reservations.filter((entry) => entry.id !== request.reservationId);
    await this.state.storage.put(RESERVATIONS_KEY, remaining);
    return {
      ok: true,
      snapshot: this.snapshot(await this.latestPeriod(), remaining, ZERO_LIMITS),
    };
  }

  private async operationLookup(key: string, now: number): Promise<SettlementReceipt | null> {
    await this.loadReservations(now);
    return (await this.state.storage.get<SettlementReceipt>(receiptKey(key))) ?? null;
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
      const period = await this.loadPeriod(request.period);
      const snapshot = this.snapshot(period, reservations, request.limits);
      const occupied = request.unitKind === 'tokens' ? snapshot.tokensUsed : snapshot.audioSecondsUsed;
      const limit = request.unitKind === 'tokens' ? request.limits.monthlyTokens : request.limits.monthlyAudioSeconds;
      if (occupied + request.units > limit) return { ok: false, receipt: null, reason: 'quota_exceeded' };
      const next: SettlementReceipt = {
        schemaVersion: 1, userId: request.userId, idempotencyKey: request.idempotencyKey,
        operation: request.operation, reservationId: crypto.randomUUID(), ledgerEntryId: crypto.randomUUID(),
        ownerId: request.ownerId, provider: request.provider, model: request.model, unitKind: request.unitKind,
        billingPeriod: request.period, reservedUnits: request.units, phase: 'reserved', revision: 1,
        createdAt: request.nowSeconds, updatedAt: request.nowSeconds,
        expiresAt: request.nowSeconds + request.limits.leaseSeconds,
        correlationId: request.correlationId, reconcileAttempts: 0,
      };
      await this.state.storage.put({
        [receiptKey(next.idempotencyKey)]: next,
        [QuotaDurableObject.periodKey(period.period)]: period,
        [LATEST_PERIOD_KEY]: period.period,
        [RESERVATIONS_KEY]: [...reservations, { id: next.reservationId, period: next.billingPeriod,
          unitKind: next.unitKind, units: next.reservedUnits, countsAsSession: false,
          expiresAt: next.expiresAt, operationKey: next.idempotencyKey }],
      });
      return { ok: true, receipt: next };
    }
    if (receipt === null || receipt.ownerId !== request.ownerId) return { ok: false, receipt, reason: 'conflict' };
    if (request.kind === 'operation_measure' && (receipt.phase === 'ledger_pending' || receipt.phase === 'settled')) {
      return { ok: receipt.actualUnits === request.actualUnits && receipt.measuredAt === request.measuredAt,
        receipt, reason: 'conflict' };
    }
    if (receipt.revision !== request.revision) return { ok: false, receipt, reason: 'conflict' };
    const next: SettlementReceipt = { ...receipt, revision: receipt.revision + 1, updatedAt: request.nowSeconds };
    if (request.kind === 'operation_start' && receipt.phase === 'reserved') {
      next.phase = 'provider_started';
    } else if (request.kind === 'operation_unknown' && (receipt.phase === 'provider_started'
      || receipt.phase === 'outcome_unknown')) {
      next.phase = 'outcome_unknown';
    } else if (request.kind === 'operation_cancel' && receipt.phase === 'reserved') {
      next.phase = 'not_started';
      const reservations = await this.loadReservations(request.nowSeconds);
      await this.state.storage.put({ [receiptKey(next.idempotencyKey)]: next,
        [RESERVATIONS_KEY]: reservations.filter((entry) => entry.id !== next.reservationId) });
      return { ok: true, receipt: next };
    } else if (request.kind === 'operation_measure' && (receipt.phase === 'provider_started'
      || receipt.phase === 'outcome_unknown')) {
      if (!Number.isSafeInteger(request.actualUnits) || request.actualUnits < 0
        || !Number.isSafeInteger(request.measuredAt) || request.measuredAt < receipt.createdAt
        || (receipt.unitKind === 'audio_seconds' && request.actualUnits > receipt.reservedUnits)) {
        return { ok: false, receipt, reason: 'conflict' };
      }
      const reservations = await this.loadReservations(request.nowSeconds);
      const period = await this.loadPeriod(receipt.billingPeriod);
      if (receipt.unitKind === 'tokens') period.tokensCommitted += request.actualUnits;
      else period.audioSecondsCommitted += request.actualUnits;
      next.phase = 'ledger_pending'; next.actualUnits = request.actualUnits;
      next.measuredAt = request.measuredAt; next.nextReconcileAt = request.nowSeconds + 30;
      // Retry is installed before the durable measurement; an extra empty alarm is harmless.
      await this.ensureAlarm(next.nextReconcileAt);
      await this.state.storage.put({ [receiptKey(next.idempotencyKey)]: next,
        [pendingKey(next)]: next.idempotencyKey,
        [QuotaDurableObject.periodKey(period.period)]: period,
        [RESERVATIONS_KEY]: reservations.filter((entry) => entry.id !== next.reservationId) });
      return { ok: true, receipt: next };
    } else return { ok: false, receipt, reason: 'conflict' };
    await this.state.storage.put(receiptKey(next.idempotencyKey), next);
    return { ok: true, receipt: next };
  }

  private async ensureAlarm(atSeconds: number): Promise<void> {
    const existing = await this.state.storage.getAlarm();
    const at = Math.max(Date.now() + 1, atSeconds * 1000);
    if (existing === null || existing > at) await this.state.storage.setAlarm(at);
  }

  private async reconcile(key: string): Promise<void> {
    const receipt = await this.state.blockConcurrencyWhile(() =>
      this.state.storage.get<SettlementReceipt>(receiptKey(key)));
    if (receipt?.phase !== 'ledger_pending' || receipt.lastFailure === 'ledger_conflict') return;
    let result: 'matched' | 'conflict' | 'unavailable';
    try {
      result = await new Repository(this.env.DB).reconcileUsage({ ledgerEntryId: receipt.ledgerEntryId,
        userId: receipt.userId, idempotencyKey: receipt.idempotencyKey, operation: receipt.operation,
        provider: receipt.provider, model: receipt.model, unitKind: receipt.unitKind,
        units: receipt.actualUnits!, billingPeriod: receipt.billingPeriod,
        correlationId: receipt.correlationId, measuredAt: receipt.measuredAt! });
    } catch { result = 'unavailable'; }
    await this.state.blockConcurrencyWhile(async () => {
      const current = await this.state.storage.get<SettlementReceipt>(receiptKey(key));
      if (current?.phase !== 'ledger_pending' || current.revision !== receipt.revision) return;
      const now = Math.floor(Date.now() / 1000);
      const next: SettlementReceipt = { ...current, revision: current.revision + 1, updatedAt: now,
        reconcileAttempts: current.reconcileAttempts + 1 };
      if (result === 'matched') {
        next.phase = 'settled'; delete next.lastFailure; delete next.nextReconcileAt;
      } else if (result === 'conflict') {
        next.lastFailure = 'ledger_conflict'; delete next.nextReconcileAt;
      } else {
        next.lastFailure = 'ledger_unavailable';
        next.nextReconcileAt = now + Math.min(900, 30 * 2 ** Math.min(5, next.reconcileAttempts - 1));
        await this.ensureAlarm(next.nextReconcileAt);
      }
      await this.state.storage.put({ [receiptKey(key)]: next,
        ...(next.nextReconcileAt === undefined ? {} : { [pendingKey(next)]: key }) });
      if (pendingKey(receipt) !== pendingKey(next)) await this.state.storage.delete(pendingKey(receipt));
    });
    // Claims are only a projection. Their failure cannot undo durable settlement.
    if (result === 'matched') {
      await new Repository(this.env.DB).completeRequestClaim({ userId: receipt.userId,
        idempotencyKey: key, nowSeconds: Math.floor(Date.now() / 1000) }).catch(() => undefined);
    }
  }

  async alarm(): Promise<void> {
    const pending = await this.state.storage.list<string>({ prefix: PENDING_PREFIX, limit: 25 });
    for (const [marker, key] of pending) {
      const receipt = await this.state.storage.get<SettlementReceipt>(receiptKey(key));
      if (receipt?.phase !== 'ledger_pending' || receipt.nextReconcileAt === undefined
        || pendingKey(receipt) !== marker) {
        await this.state.storage.delete(marker);
      } else if (receipt.nextReconcileAt <= Math.floor(Date.now() / 1000)) {
        await this.reconcile(key);
      }
    }
    await this.state.blockConcurrencyWhile(async () => {
      const first = await this.state.storage.list<string>({ prefix: PENDING_PREFIX, limit: 1 });
      const marker = first.keys().next().value as string | undefined;
      if (marker !== undefined) await this.ensureAlarm(Number(marker.slice(PENDING_PREFIX.length).split(':')[0]));
      // Do not delete a different request's newly installed alarm.
    });
  }

  private async status(request: StatusRequest): Promise<QuotaResponse> {
    // Sweep before reading so expired permits and retained unknown holds are
    // reflected alongside the unchanged legacy live-expiry accounting.
    const reservations = await this.loadReservations(request.nowSeconds);
    const period = await this.loadPeriod(request.period);
    return { ok: true, snapshot: this.snapshot(period, reservations, request.limits) };
  }
}

/**
 * Limits are supplied by the caller on requests that need to enforce them.
 * Finalise and release only report usage, so they use a zero-limit placeholder
 * rather than pretending to know the plan.
 */
const ZERO_LIMITS: QuotaLimits = {
  monthlyAudioSeconds: 0,
  monthlyTokens: 0,
  maxConcurrentSessions: 0,
  leaseSeconds: 0,
};
