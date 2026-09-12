import { describe, expect, it } from 'vitest';
import {
  allRoutes,
  bestRoute,
  isPaidOperation,
  policyDocument,
  POLICY_VERSION,
} from '../src/policy.js';

describe('canonical Best routing policy', () => {
  it('resolves every paid operation to exactly one route', () => {
    const operations = allRoutes().map((route) => route.operation);
    expect(new Set(operations).size).toBe(operations.length);
    expect(operations).toEqual(
      expect.arrayContaining(['live_transcription', 'batch_transcription', 'post_processing']),
    );
  });

  it('routes live transcription over a websocket transport', () => {
    const route = bestRoute('live_transcription');
    expect(route.transport).toBe('websocket');
    expect(route.provider).toBe('deepgram');
    expect(route.unitKind).toBe('audio_seconds');
  });

  it('routes batch transcription and post-processing over https', () => {
    expect(bestRoute('batch_transcription').transport).toBe('https');
    expect(bestRoute('post_processing').transport).toBe('https');
  });

  it('meters post-processing in tokens and transcription in audio seconds', () => {
    expect(bestRoute('post_processing').unitKind).toBe('tokens');
    expect(bestRoute('batch_transcription').unitKind).toBe('audio_seconds');
  });

  it('uses catalogue identifiers the Swift clients also know about', () => {
    expect(bestRoute('live_transcription').catalogueModelId).toBe('deepgram/nova-3-streaming');
    expect(bestRoute('batch_transcription').catalogueModelId).toBe('google/gemini-2.0-flash-001');
    expect(bestRoute('post_processing').catalogueModelId).toBe('openai/gpt-5-mini');
  });

  it('rejects operations that are not part of the paid surface', () => {
    expect(isPaidOperation('live_transcription')).toBe(true);
    expect(isPaidOperation('translation')).toBe(false);
    expect(isPaidOperation('')).toBe(false);
  });

  it('publishes a versioned policy document with display names', () => {
    const document = policyDocument();
    expect(document.version).toBe(POLICY_VERSION);
    expect(document.routes).toHaveLength(3);
    for (const route of document.routes) {
      expect(route.display_name.length).toBeGreaterThan(0);
      expect(route.model.length).toBeGreaterThan(0);
    }
  });
});
