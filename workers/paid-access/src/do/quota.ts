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

const PERIOD_KEY = 'period';
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

  private async loadPeriod(period: string): Promise<PeriodState> {
    const stored = await this.state.storage.get<PeriodState>(PERIOD_KEY);
    if (stored === undefined || stored.period !== period) {
      // A new billing period resets committed usage; the ledger in D1 remains
      // the durable record.
      return { period, audioSecondsCommitted: 0, tokensCommitted: 0 };
    }
    return stored;
  }

  private async loadReservations(nowSeconds: number): Promise<Reservation[]> {
    const stored = (await this.state.storage.get<Reservation[]>(RESERVATIONS_KEY)) ?? [];
    return stored.filter((reservation) => reservation.expiresAt > nowSeconds);
  }

  private snapshot(
    period: PeriodState,
    reservations: readonly Reservation[],
    limits: QuotaLimits,
  ): QuotaSnapshot {
    const reservedAudio = reservations
      .filter((entry) => entry.unitKind === 'audio_seconds')
      .reduce((total, entry) => total + entry.units, 0);
    const reservedTokens = reservations
      .filter((entry) => entry.unitKind === 'tokens')
      .reduce((total, entry) => total + entry.units, 0);
    return {
      period: period.period,
      audioSecondsUsed: period.audioSecondsCommitted + reservedAudio,
      audioSecondsLimit: limits.monthlyAudioSeconds,
      tokensUsed: period.tokensCommitted + reservedTokens,
      tokensLimit: limits.monthlyTokens,
      activeSessions: reservations.filter((entry) => entry.countsAsSession).length,
      maxConcurrentSessions: limits.maxConcurrentSessions,
    };
  }

  private async reserve(request: ReserveRequest): Promise<QuotaResponse> {
    if (!Number.isFinite(request.units) || request.units < 0) {
      throw new Error('Reservation units must be a non-negative number');
    }
    const period = await this.loadPeriod(request.period);
    const reservations = await this.loadReservations(request.nowSeconds);
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
    await this.state.storage.put(PERIOD_KEY, period);
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
      // The lease already expired, or this is a duplicate finalise. Both are
      // safe no-ops: committed usage is authoritative in D1's ledger.
      const period = await this.loadPeriod(
        (await this.state.storage.get<PeriodState>(PERIOD_KEY))?.period ?? '1970-01',
      );
      await this.state.storage.put(RESERVATIONS_KEY, remaining);
      return { ok: true, snapshot: this.snapshot(period, remaining, ZERO_LIMITS) };
    }

    const period = await this.loadPeriod(reservation.period);
    // Charge the smaller of measured and reserved: the reservation was the
    // agreed upper bound, so an over-reporting client cannot exceed it.
    const charged = Math.max(0, Math.min(Math.ceil(request.actualUnits), reservation.units));
    const updated: PeriodState = {
      period: period.period,
      audioSecondsCommitted:
        period.audioSecondsCommitted + (reservation.unitKind === 'audio_seconds' ? charged : 0),
      tokensCommitted: period.tokensCommitted + (reservation.unitKind === 'tokens' ? charged : 0),
    };

    await this.state.storage.put(PERIOD_KEY, updated);
    await this.state.storage.put(RESERVATIONS_KEY, remaining);

    return { ok: true, snapshot: this.snapshot(updated, remaining, ZERO_LIMITS) };
  }

  private async release(request: ReleaseRequest): Promise<QuotaResponse> {
    const reservations = await this.loadReservations(request.nowSeconds);
    const remaining = reservations.filter((entry) => entry.id !== request.reservationId);
    await this.state.storage.put(RESERVATIONS_KEY, remaining);
    const period = await this.loadPeriod(
      (await this.state.storage.get<PeriodState>(PERIOD_KEY))?.period ?? '1970-01',
    );
    return { ok: true, snapshot: this.snapshot(period, remaining, ZERO_LIMITS) };
  }

  private async status(request: StatusRequest): Promise<QuotaResponse> {
    const period = await this.loadPeriod(request.period);
    const reservations = await this.loadReservations(request.nowSeconds);
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
