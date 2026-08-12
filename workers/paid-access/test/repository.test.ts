import { env } from 'cloudflare:test';
import { describe, expect, it } from 'vitest';
import { Repository } from '../src/data/repository.js';

const NOW = 1_800_000_000;

function repository(): Repository {
  return new Repository(env.DB);
}

async function seedUser(): Promise<string> {
  const user = await repository().upsertUserByAppleSub(`apple-${crypto.randomUUID()}`, null, NOW);
  return user.id;
}

describe('usage ledger idempotency', () => {
  it('records a usage row once', async () => {
    const repo = repository();
    const userId = await seedUser();
    const written = await repo.recordUsage({
      userId,
      idempotencyKey: 'request-key-0000000000000001',
      operation: 'post_processing',
      provider: 'openrouter',
      model: 'openai/gpt-5-mini',
      unitKind: 'tokens',
      units: 120,
      billingPeriod: '2027-01',
      correlationId: 'corr-1',
      nowSeconds: NOW,
    });
    expect(written).toBe(true);

    const totals = await repo.usageTotals(userId, '2027-01');
    expect(totals.tokens).toBe(120);
  });

  it('ignores a replayed write with the same idempotency key', async () => {
    const repo = repository();
    const userId = await seedUser();
    const input = {
      userId,
      idempotencyKey: 'request-key-0000000000000002',
      operation: 'batch_transcription' as const,
      provider: 'openrouter',
      model: 'google/gemini-2.0-flash-001',
      unitKind: 'audio_seconds' as const,
      units: 45,
      billingPeriod: '2027-01',
      correlationId: 'corr-2',
      nowSeconds: NOW,
    };

    expect(await repo.recordUsage(input)).toBe(true);
    expect(await repo.recordUsage(input)).toBe(false);

    const totals = await repo.usageTotals(userId, '2027-01');
    expect(totals.audioSeconds).toBe(45);
  });

  it('scopes idempotency keys per user', async () => {
    const repo = repository();
    const first = await seedUser();
    const second = await seedUser();
    const key = 'shared-key-000000000000000003';

    expect(
      await repo.recordUsage({
        userId: first,
        idempotencyKey: key,
        operation: 'post_processing',
        provider: 'openrouter',
        model: 'openai/gpt-5-mini',
        unitKind: 'tokens',
        units: 10,
        billingPeriod: '2027-01',
        correlationId: 'corr-3',
        nowSeconds: NOW,
      }),
    ).toBe(true);

    expect(
      await repo.recordUsage({
        userId: second,
        idempotencyKey: key,
        operation: 'post_processing',
        provider: 'openrouter',
        model: 'openai/gpt-5-mini',
        unitKind: 'tokens',
        units: 10,
        billingPeriod: '2027-01',
        correlationId: 'corr-3',
        nowSeconds: NOW,
      }),
    ).toBe(true);
  });

  it('refuses to record negative usage', async () => {
    const repo = repository();
    const userId = await seedUser();
    await expect(
      repo.recordUsage({
        userId,
        idempotencyKey: 'negative-key-00000000000004',
        operation: 'post_processing',
        provider: 'openrouter',
        model: 'openai/gpt-5-mini',
        unitKind: 'tokens',
        units: -5,
        billingPeriod: '2027-01',
        correlationId: 'corr-4',
        nowSeconds: NOW,
      }),
    ).rejects.toThrow();
  });

  it('keeps usage totals partitioned by billing period', async () => {
    const repo = repository();
    const userId = await seedUser();
    await repo.recordUsage({
      userId,
      idempotencyKey: 'jan-key-000000000000000005',
      operation: 'post_processing',
      provider: 'openrouter',
      model: 'openai/gpt-5-mini',
      unitKind: 'tokens',
      units: 100,
      billingPeriod: '2027-01',
      correlationId: 'corr-5',
      nowSeconds: NOW,
    });
    await repo.recordUsage({
      userId,
      idempotencyKey: 'feb-key-000000000000000006',
      operation: 'post_processing',
      provider: 'openrouter',
      model: 'openai/gpt-5-mini',
      unitKind: 'tokens',
      units: 7,
      billingPeriod: '2027-02',
      correlationId: 'corr-6',
      nowSeconds: NOW,
    });

    expect((await repo.usageTotals(userId, '2027-01')).tokens).toBe(100);
    expect((await repo.usageTotals(userId, '2027-02')).tokens).toBe(7);
  });
});

describe('append-only enforcement', () => {
  it('rejects an UPDATE to the usage ledger at the database level', async () => {
    const repo = repository();
    const userId = await seedUser();
    await repo.recordUsage({
      userId,
      idempotencyKey: 'immutable-key-0000000000007',
      operation: 'post_processing',
      provider: 'openrouter',
      model: 'openai/gpt-5-mini',
      unitKind: 'tokens',
      units: 42,
      billingPeriod: '2027-01',
      correlationId: 'corr-7',
      nowSeconds: NOW,
    });

    await expect(
      env.DB.prepare('UPDATE usage_ledger SET units = 0 WHERE user_id = ?1').bind(userId).run(),
    ).rejects.toThrow();
  });

  it('rejects a DELETE from the usage ledger at the database level', async () => {
    const repo = repository();
    const userId = await seedUser();
    await repo.recordUsage({
      userId,
      idempotencyKey: 'immutable-key-0000000000008',
      operation: 'post_processing',
      provider: 'openrouter',
      model: 'openai/gpt-5-mini',
      unitKind: 'tokens',
      units: 42,
      billingPeriod: '2027-01',
      correlationId: 'corr-8',
      nowSeconds: NOW,
    });

    await expect(
      env.DB.prepare('DELETE FROM usage_ledger WHERE user_id = ?1').bind(userId).run(),
    ).rejects.toThrow();
  });

  it('rejects tampering with the entitlement audit trail', async () => {
    const userId = await seedUser();
    await env.DB.prepare(
      `INSERT INTO entitlement_events
         (id, user_id, from_status, to_status, source, reason, correlation_id, created_at)
       VALUES (?1, ?2, 'none', 'active', 'stripe', 'test', 'corr-9', ?3)`,
    )
      .bind(crypto.randomUUID(), userId, NOW)
      .run();

    await expect(
      env.DB.prepare('DELETE FROM entitlement_events WHERE user_id = ?1').bind(userId).run(),
    ).rejects.toThrow();
    await expect(
      env.DB.prepare('UPDATE entitlement_events SET to_status = ?2 WHERE user_id = ?1')
        .bind(userId, 'revoked')
        .run(),
    ).rejects.toThrow();
  });
});

describe('database constraints', () => {
  it('resolves the same Apple subject to one user across sign-ins', async () => {
    const repo = repository();
    const appleSub = `apple-${crypto.randomUUID()}`;
    const first = await repo.upsertUserByAppleSub(appleSub, null, NOW);
    const second = await repo.upsertUserByAppleSub(appleSub, 'person@example.com', NOW + 10);
    expect(second.id).toBe(first.id);
    expect(second.email).toBe('person@example.com');
  });

  it('refuses to give one subscription reference to two users', async () => {
    const repo = repository();
    const first = await seedUser();
    const second = await seedUser();
    await repo.ensureEntitlement(first, NOW);
    await repo.ensureEntitlement(second, NOW);

    await env.DB.prepare(
      `UPDATE entitlements SET source = 'stripe', source_reference = 'sub_shared' WHERE user_id = ?1`,
    )
      .bind(first)
      .run();

    await expect(
      env.DB.prepare(
        `UPDATE entitlements SET source = 'stripe', source_reference = 'sub_shared' WHERE user_id = ?1`,
      )
        .bind(second)
        .run(),
    ).rejects.toThrow();
  });

  it('refuses an entitlement row with an unknown status', async () => {
    const userId = await seedUser();
    await repository().ensureEntitlement(userId, NOW);
    await expect(
      env.DB.prepare('UPDATE entitlements SET status = ?2 WHERE user_id = ?1')
        .bind(userId, 'super_active')
        .run(),
    ).rejects.toThrow();
  });

  it('refuses a revoked entitlement with no revocation timestamp', async () => {
    const userId = await seedUser();
    await repository().ensureEntitlement(userId, NOW);
    await expect(
      env.DB.prepare('UPDATE entitlements SET status = ?2 WHERE user_id = ?1')
        .bind(userId, 'revoked')
        .run(),
    ).rejects.toThrow();
  });

  it('refuses a period that ends before it starts', async () => {
    const userId = await seedUser();
    await repository().ensureEntitlement(userId, NOW);
    await expect(
      env.DB.prepare(
        'UPDATE entitlements SET current_period_start = ?2, current_period_end = ?3 WHERE user_id = ?1',
      )
        .bind(userId, NOW, NOW - 100)
        .run(),
    ).rejects.toThrow();
  });

  it('gives each user at most one entitlement row', async () => {
    const repo = repository();
    const userId = await seedUser();
    const first = await repo.ensureEntitlement(userId, NOW);
    const second = await repo.ensureEntitlement(userId, NOW + 5);
    expect(second.id).toBe(first.id);
  });
});

describe('refresh token rotation', () => {
  it('allows a refresh token to be consumed exactly once', async () => {
    const repo = repository();
    const userId = await seedUser();
    const hash = 'a'.repeat(64);
    await repo.createAuthSession({
      userId,
      refreshTokenHash: hash,
      deviceLabel: null,
      createdAt: NOW,
      expiresAt: NOW + 3_600,
    });

    expect(await repo.consumeRefreshToken(hash, NOW)).not.toBeNull();
    expect(await repo.consumeRefreshToken(hash, NOW)).toBeNull();
  });

  it('refuses an expired refresh token', async () => {
    const repo = repository();
    const userId = await seedUser();
    const hash = 'b'.repeat(64);
    await repo.createAuthSession({
      userId,
      refreshTokenHash: hash,
      deviceLabel: null,
      createdAt: NOW - 7_200,
      expiresAt: NOW - 60,
    });

    expect(await repo.consumeRefreshToken(hash, NOW)).toBeNull();
  });
});
