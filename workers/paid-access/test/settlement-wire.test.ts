import { describe, expect, it } from 'vitest';
import fixture from '../fixtures/settlement-wire-v1.json';
import { ApiError, errorResponse, type ErrorCode } from '../src/http.js';
import { retainedOperation, SETTLEMENT_HEADER, SETTLEMENT_VERSION } from '../src/routes/settlement.js';
import type { SettlementPhase, SettlementReceipt } from '../src/do/settlement.js';

/**
 * The Worker side of the shared settlement wire fixture. SpeakCore's
 * PaidSettlementWireFixtureTests decodes the same file, so a change to a code,
 * status or envelope on either side fails until both agree.
 */
describe('settlement wire fixture v1', () => {
  it('names this contract version and its request header', () => {
    expect(fixture.contract).toBe('paid-settlement');
    expect(fixture.version).toBe(1);
    expect(fixture.requestHeader.name.toLowerCase()).toBe(SETTLEMENT_HEADER);
    expect(fixture.requestHeader.value).toBe(SETTLEMENT_VERSION);
  });

  it.each(fixture.errors.map(entry => [entry.name, entry] as const))('%s is sent as the fixture envelope', async (_name, entry) => {
    const error = new ApiError(entry.body.error.code as ErrorCode, entry.body.error.message);
    const response = errorResponse(error, entry.body.error.correlation_id);
    expect(response.status).toBe(entry.status);
    expect(await response.json()).toEqual(entry.body);
  });

  it.each(fixture.retainedPhases.map(entry => [entry.phase, entry] as const))('a retained %s receipt answers with its code', (_phase, entry) => {
    const receipt = { phase: entry.phase as SettlementPhase } as SettlementReceipt;
    const current = new Request('https://api.test/v1/paid/post-process',
      { headers: { [SETTLEMENT_HEADER]: SETTLEMENT_VERSION } });
    const legacy = new Request('https://api.test/v1/paid/post-process');
    expect(retainedOperation(current, receipt).code).toBe(entry.code);
    expect(retainedOperation(legacy, receipt).code).toBe(entry.legacyCode);
  });

  it('describes how the client reads every retained code', () => {
    const submitted = new Set(fixture.errors.filter(entry => entry.submitted).map(entry => entry.body.error.code));
    for (const entry of fixture.retainedPhases) {
      expect(submitted).toContain(entry.code);
      expect(submitted).toContain(entry.legacyCode);
    }
  });
});
