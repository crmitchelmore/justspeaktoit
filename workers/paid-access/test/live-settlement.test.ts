import { env, runInDurableObject } from 'cloudflare:test';
import { describe, expect, it, vi } from 'vitest';
import { QuotaClient, QuotaSettlement } from '../src/quota.js';

describe('live settlement retry', () => {
  it('retains the measured outcome and alarm until quota accepts it', async () => {
    const userId = crypto.randomUUID();
    const quota = new QuotaClient(env.QUOTA, { monthlyAudioSeconds: 2000, monthlyTokens: 1000,
      maxConcurrentSessions: 2, leaseSeconds: 1900 });
    const now = Math.floor(Date.now() / 1000);
    const reservation = await quota.reserve({ userId, period: '2027-01', unitKind: 'audio_seconds',
      units: 1800, countsAsSession: true, nowSeconds: now });
    const stub = env.LIVE_SESSION.get(env.LIVE_SESSION.idFromName(crypto.randomUUID()));
    await runInDurableObject(stub, async (instance, state) => {
      await state.storage.put('metadata', { userId, reservationId: reservation.reservationId,
        billingPeriod: '2027-01', maxSessionSeconds: 1800, startedAtMs: Date.now() - 6500 });
      const finalise = vi.spyOn(QuotaSettlement.prototype, 'finalise').mockRejectedValueOnce(new Error('offline'));
      try {
        await instance.alarm!();
        const outcome = await state.storage.get<{ elapsedSeconds: number }>('outcome');
        expect(outcome?.elapsedSeconds).toBe(7);
        expect(await state.storage.get('settled')).not.toBe(true);
        expect(await state.storage.getAlarm()).not.toBeNull();
        await instance.alarm!();
        expect(finalise).toHaveBeenLastCalledWith(expect.objectContaining({ actualUnits: 7 }));
        expect(await state.storage.get('settled')).toBe(true);
        expect(await state.storage.getAlarm()).toBeNull();
      } finally {
        finalise.mockRestore();
      }
    });
    expect((await quota.status(userId, '2027-01', now)).audioSecondsUsed).toBe(7);
  });
});
