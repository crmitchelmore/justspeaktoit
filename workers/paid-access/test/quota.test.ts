import { env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { QuotaClient } from '../src/quota.js';
import { ApiError } from '../src/http.js';
import type { QuotaLimits } from '../src/do/quota.js';

const NOW = 1_800_000_000;
const PERIOD = '2027-01';

function client(overrides: Partial<QuotaLimits> = {}): QuotaClient {
  return new QuotaClient(env.QUOTA, {
    monthlyAudioSeconds: 100,
    monthlyTokens: 1_000,
    maxConcurrentSessions: 2,
    leaseSeconds: 60,
    ...overrides,
  });
}

function newUser(): string {
  return `quota-user-${crypto.randomUUID()}`;
}

describe('quota reservation', () => {
  it('reserves within the monthly allowance', async () => {
    const quota = client();
    const userId = newUser();
    const reservation = await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 30,
      countsAsSession: false,
      nowSeconds: NOW,
    });
    expect(reservation.reservationId).toBeTruthy();
    expect(reservation.snapshot.audioSecondsUsed).toBe(30);
  });

  it('denies a reservation that would exceed the monthly allowance', async () => {
    const quota = client();
    const userId = newUser();
    await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 90,
      countsAsSession: false,
      nowSeconds: NOW,
    });

    await expect(
      quota.reserve({
        userId,
        period: PERIOD,
        unitKind: 'audio_seconds',
        units: 20,
        countsAsSession: false,
        nowSeconds: NOW,
      }),
    ).rejects.toMatchObject({ code: 'quota_exceeded' });
  });

  it('denies a reservation once the concurrent session limit is reached', async () => {
    const quota = client({ maxConcurrentSessions: 1 });
    const userId = newUser();
    await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 10,
      countsAsSession: true,
      nowSeconds: NOW,
    });

    await expect(
      quota.reserve({
        userId,
        period: PERIOD,
        unitKind: 'audio_seconds',
        units: 10,
        countsAsSession: true,
        nowSeconds: NOW,
      }),
    ).rejects.toMatchObject({ code: 'too_many_sessions' });
  });

  it('surfaces denials as errors so a caller cannot proceed on a falsy result', async () => {
    const quota = client({ monthlyAudioSeconds: 1 });
    const userId = newUser();
    await expect(
      quota.reserve({
        userId,
        period: PERIOD,
        unitKind: 'audio_seconds',
        units: 5,
        countsAsSession: false,
        nowSeconds: NOW,
      }),
    ).rejects.toBeInstanceOf(ApiError);
  });

  it('keeps quota separate per user', async () => {
    const quota = client();
    const first = newUser();
    const second = newUser();
    await quota.reserve({
      userId: first,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 100,
      countsAsSession: false,
      nowSeconds: NOW,
    });
    const other = await quota.reserve({
      userId: second,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 100,
      countsAsSession: false,
      nowSeconds: NOW,
    });
    expect(other.reservationId).toBeTruthy();
  });

  it('resets the allowance when the billing period rolls over', async () => {
    const quota = client();
    const userId = newUser();
    const reservation = await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 100,
      countsAsSession: false,
      nowSeconds: NOW,
    });
    await quota.finalise({
      userId,
      reservationId: reservation.reservationId,
      actualUnits: 100,
      nowSeconds: NOW,
    });

    const nextPeriod = await quota.reserve({
      userId,
      period: '2027-02',
      unitKind: 'audio_seconds',
      units: 100,
      countsAsSession: false,
      nowSeconds: NOW + 2_678_400,
    });
    expect(nextPeriod.reservationId).toBeTruthy();
  });
});

describe('quota release and finalisation', () => {
  it('returns a released reservation to the allowance', async () => {
    const quota = client();
    const userId = newUser();
    const reservation = await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 100,
      countsAsSession: false,
      nowSeconds: NOW,
    });
    await quota.release({ userId, reservationId: reservation.reservationId, nowSeconds: NOW });

    const snapshot = await quota.status(userId, PERIOD, NOW);
    expect(snapshot.audioSecondsUsed).toBe(0);

    const retry = await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 100,
      countsAsSession: false,
      nowSeconds: NOW,
    });
    expect(retry.reservationId).toBeTruthy();
  });

  it('frees a concurrent session slot when the session is released', async () => {
    const quota = client({ maxConcurrentSessions: 1 });
    const userId = newUser();
    const first = await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 10,
      countsAsSession: true,
      nowSeconds: NOW,
    });
    await quota.release({ userId, reservationId: first.reservationId, nowSeconds: NOW });

    const second = await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 10,
      countsAsSession: true,
      nowSeconds: NOW,
    });
    expect(second.reservationId).toBeTruthy();
  });

  it('commits only the measured amount and gives the remainder back', async () => {
    const quota = client();
    const userId = newUser();
    const reservation = await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 90,
      countsAsSession: false,
      nowSeconds: NOW,
    });
    await quota.finalise({
      userId,
      reservationId: reservation.reservationId,
      actualUnits: 10,
      nowSeconds: NOW,
    });

    const snapshot = await quota.status(userId, PERIOD, NOW);
    expect(snapshot.audioSecondsUsed).toBe(10);
  });

  it('never commits more than was reserved even if the measurement over-reports', async () => {
    const quota = client();
    const userId = newUser();
    const reservation = await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 20,
      countsAsSession: false,
      nowSeconds: NOW,
    });
    await quota.finalise({
      userId,
      reservationId: reservation.reservationId,
      actualUnits: 10_000,
      nowSeconds: NOW,
    });

    const snapshot = await quota.status(userId, PERIOD, NOW);
    expect(snapshot.audioSecondsUsed).toBe(20);
  });

  it('treats a repeated finalise as a no-op', async () => {
    const quota = client();
    const userId = newUser();
    const reservation = await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 30,
      countsAsSession: false,
      nowSeconds: NOW,
    });
    await quota.finalise({
      userId,
      reservationId: reservation.reservationId,
      actualUnits: 30,
      nowSeconds: NOW,
    });
    await quota.finalise({
      userId,
      reservationId: reservation.reservationId,
      actualUnits: 30,
      nowSeconds: NOW,
    });

    const snapshot = await quota.status(userId, PERIOD, NOW);
    expect(snapshot.audioSecondsUsed).toBe(30);
  });

  it('commits a reservation whose lease expired rather than giving the usage away', async () => {
    const quota = client({ monthlyAudioSeconds: 100, leaseSeconds: 30 });
    const userId = newUser();
    await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 50,
      countsAsSession: true,
      nowSeconds: NOW,
    });

    // Nothing finalised or released this: the client crashed, or the Worker did.
    // The reserved amount was the agreed upper bound for that work, so it is
    // what gets metered — silently releasing it would hand the usage away free.
    const snapshot = await quota.status(userId, PERIOD, NOW + 31);
    expect(snapshot.audioSecondsUsed).toBe(50);
    // ...and the concurrency slot is freed, so the user can start again.
    expect(snapshot.activeSessions).toBe(0);

    const afterLease = await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 50,
      countsAsSession: true,
      nowSeconds: NOW + 31,
    });
    expect(afterLease.reservationId).toBeTruthy();
  });

  it('finalising last month does not disturb this month', async () => {
    // The reservation outlives the month boundary, so the finalise below is a
    // genuine cross-period commit rather than an expired lease being swept up.
    const quota = client({ monthlyAudioSeconds: 100, leaseSeconds: 5_000_000 });
    const userId = newUser();
    const nextMonth = NOW + 2_678_400;

    const january = await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 40,
      countsAsSession: false,
      nowSeconds: NOW,
    });

    const february = await quota.reserve({
      userId,
      period: '2027-02',
      unitKind: 'audio_seconds',
      units: 25,
      countsAsSession: false,
      nowSeconds: nextMonth,
    });
    await quota.finalise({
      userId,
      reservationId: february.reservationId,
      actualUnits: 25,
      nowSeconds: nextMonth,
    });

    // The late finalise belongs to January and must land there.
    await quota.finalise({
      userId,
      reservationId: january.reservationId,
      actualUnits: 40,
      nowSeconds: nextMonth,
    });

    expect((await quota.status(userId, '2027-02', nextMonth)).audioSecondsUsed).toBe(25);
    expect((await quota.status(userId, PERIOD, nextMonth)).audioSecondsUsed).toBe(40);
  });

  it('meters tokens and audio seconds against separate allowances', async () => {
    const quota = client();
    const userId = newUser();
    await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'audio_seconds',
      units: 100,
      countsAsSession: false,
      nowSeconds: NOW,
    });
    const tokens = await quota.reserve({
      userId,
      period: PERIOD,
      unitKind: 'tokens',
      units: 500,
      countsAsSession: false,
      nowSeconds: NOW,
    });
    expect(tokens.snapshot.tokensUsed).toBe(500);
    expect(tokens.snapshot.audioSecondsUsed).toBe(100);
  });
});
