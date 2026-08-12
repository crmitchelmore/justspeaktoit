/**
 * Typed client for the quota Durable Object.
 *
 * Application code never constructs DO requests by hand; it goes through this
 * module so the reserve → finalise/release lifecycle is impossible to get
 * half-right at a call site.
 */

import { ApiError } from './http.js';
import type {
  QuotaLimits,
  QuotaResponse,
  QuotaSnapshot,
  QuotaUnitKind,
} from './do/quota.js';

export type { QuotaLimits, QuotaSnapshot, QuotaUnitKind };

export interface QuotaReservation {
  readonly reservationId: string;
  readonly snapshot: QuotaSnapshot;
}

export class QuotaClient {
  private readonly namespace: DurableObjectNamespace;
  private readonly limits: QuotaLimits;

  constructor(namespace: DurableObjectNamespace, limits: QuotaLimits) {
    this.namespace = namespace;
    this.limits = limits;
  }

  private stub(userId: string): DurableObjectStub {
    return this.namespace.get(this.namespace.idFromName(`user:${userId}`));
  }

  private async call(userId: string, body: unknown): Promise<QuotaResponse> {
    const response = await this.stub(userId).fetch('https://quota.invalid/', {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!response.ok) {
      throw new ApiError('internal_error', 'Quota service is unavailable');
    }
    return (await response.json());
  }

  /**
   * Reserves an upper bound of usage. Throws `quota_exceeded` or
   * `too_many_sessions` rather than returning a falsy value, so a caller cannot
   * accidentally proceed on a denial.
   */
  async reserve(input: {
    userId: string;
    period: string;
    unitKind: QuotaUnitKind;
    units: number;
    countsAsSession: boolean;
    nowSeconds: number;
  }): Promise<QuotaReservation> {
    const result = await this.call(input.userId, {
      kind: 'reserve',
      period: input.period,
      unitKind: input.unitKind,
      units: input.units,
      countsAsSession: input.countsAsSession,
      limits: this.limits,
      nowSeconds: input.nowSeconds,
    });

    if (result.ok === false) {
      throw new ApiError(
        result.reason,
        result.reason === 'quota_exceeded'
          ? 'Monthly included usage for this plan has been used up'
          : 'Too many concurrent sessions for this account',
      );
    }
    if (!('reservationId' in result)) {
      throw new ApiError('internal_error', 'Quota service returned no reservation');
    }
    return { reservationId: result.reservationId, snapshot: result.snapshot };
  }

  async finalise(input: {
    userId: string;
    reservationId: string;
    actualUnits: number;
    nowSeconds: number;
  }): Promise<void> {
    await this.call(input.userId, {
      kind: 'finalise',
      reservationId: input.reservationId,
      actualUnits: input.actualUnits,
      nowSeconds: input.nowSeconds,
    });
  }

  async release(input: {
    userId: string;
    reservationId: string;
    nowSeconds: number;
  }): Promise<void> {
    await this.call(input.userId, {
      kind: 'release',
      reservationId: input.reservationId,
      nowSeconds: input.nowSeconds,
    });
  }

  async status(userId: string, period: string, nowSeconds: number): Promise<QuotaSnapshot> {
    const result = await this.call(userId, {
      kind: 'status',
      period,
      limits: this.limits,
      nowSeconds,
    });
    return result.snapshot;
  }
}
