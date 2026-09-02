/**
 * Per-user quota and concurrency enforcement.
 *
 * One Durable Object instance per user gives us a single-threaded serialisation
 * point, which is what makes reserve/finalise correct: two devices starting a
 * long recording at the same moment cannot both pass a check-then-act race, and
 * a crashed client cannot leak a reservation forever because reservations carry
 * a lease that expires.
 *
 * Quota is never trusted from the client. Callers reserve an upper bound before
 * work starts and finalise with the *measured* amount afterwards; the delta is
 * released back.
 */

export interface QuotaLimits {
  readonly monthlyAudioSeconds: number;
  readonly monthlyTokens: number;
  readonly maxConcurrentSessions: number;
  /** How long an unfinalised reservation is honoured before being reclaimed. */
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
}

interface PeriodState {
  period: string;
  audioSecondsCommitted: number;
  tokensCommitted: number;
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

export class QuotaDurableObject implements DurableObject {
  private readonly state: DurableObjectState;

  constructor(state: DurableObjectState) {
    this.state = state;
  }

  async fetch(request: Request): Promise<Response> {
    if (request.method !== 'POST') {
      return new Response('Method Not Allowed', { status: 405 });
    }
    let body: QuotaRequest;
    try {
      body = (await request.json());
    } catch {
      return new Response('Bad Request', { status: 400 });
    }

    // `blockConcurrencyWhile` is what makes reserve/finalise atomic against
    // other requests for the same user.
    const response = await this.state.blockConcurrencyWhile(() => this.handle(body));
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
    return { period, audioSecondsCommitted: 0, tokensCommitted: 0 };
  }

  /**
   * Adds committed usage to one period without touching any other.
   *
   * This is the only writer of committed usage, so a finalise arriving after a
   * period boundary cannot silently reset the period now being metered.
   */
  private async commit(
    period: string,
    unitKind: QuotaUnitKind,
    units: number,
  ): Promise<PeriodState> {
    const current = await this.loadPeriod(period);
    const updated: PeriodState = {
      period,
      audioSecondsCommitted:
        current.audioSecondsCommitted + (unitKind === 'audio_seconds' ? units : 0),
      tokensCommitted: current.tokensCommitted + (unitKind === 'tokens' ? units : 0),
    };
    await this.state.storage.put(QuotaDurableObject.periodKey(period), updated);
    return updated;
  }

  /**
   * Returns the reservations still under lease, committing any that expired.
   *
   * A lease expires only when nothing finalised or released it — a crashed
   * Worker, a device that vanished mid-session. The reserved amount was the
   * agreed upper bound for that work, so committing it is the only outcome that
   * cannot hand the usage away for free; anything genuinely smaller would have
   * arrived through `finalise` before the lease ran out.
   */
  private async loadReservations(nowSeconds: number): Promise<Reservation[]> {
    const stored = (await this.state.storage.get<Reservation[]>(RESERVATIONS_KEY)) ?? [];
    const live: Reservation[] = [];
    const expired: Reservation[] = [];
    for (const reservation of stored) {
      (reservation.expiresAt > nowSeconds ? live : expired).push(reservation);
    }
    if (expired.length > 0) {
      for (const reservation of expired) {
        await this.commit(reservation.period, reservation.unitKind, reservation.units);
      }
      await this.state.storage.put(RESERVATIONS_KEY, live);
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
    const reservations = await this.loadReservations(request.nowSeconds);
    const reservation = reservations.find((entry) => entry.id === request.reservationId);
    const remaining = reservations.filter((entry) => entry.id !== request.reservationId);

    if (reservation === undefined) {
      // The lease already expired — and was therefore already committed above —
      // or this is a duplicate finalise. Both are safe no-ops.
      await this.state.storage.put(RESERVATIONS_KEY, remaining);
      return {
        ok: true,
        snapshot: this.snapshot(await this.latestPeriod(), remaining, ZERO_LIMITS),
      };
    }

    // Charge the smaller of measured and reserved: the reservation was the
    // agreed upper bound, so an over-reporting client cannot exceed it. The
    // charge lands in the reservation's own period, which may no longer be the
    // period the user is currently being metered in.
    const charged = Math.max(0, Math.min(Math.ceil(request.actualUnits), reservation.units));
    const updated = await this.commit(reservation.period, reservation.unitKind, charged);
    await this.state.storage.put(RESERVATIONS_KEY, remaining);

    return { ok: true, snapshot: this.snapshot(updated, remaining, ZERO_LIMITS) };
  }

  private async release(request: ReleaseRequest): Promise<QuotaResponse> {
    const reservations = await this.loadReservations(request.nowSeconds);
    const remaining = reservations.filter((entry) => entry.id !== request.reservationId);
    await this.state.storage.put(RESERVATIONS_KEY, remaining);
    return {
      ok: true,
      snapshot: this.snapshot(await this.latestPeriod(), remaining, ZERO_LIMITS),
    };
  }

  private async status(request: StatusRequest): Promise<QuotaResponse> {
    // Sweep before reading, so a lease that expired since the last call is
    // reported as committed usage rather than as nothing at all.
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
