import { describe, expect, it } from 'vitest';
import { wavDurationSeconds } from '../src/audio/wav.js';
import { ApiError } from '../src/http.js';

interface Geometry {
  frames: number;
  sampleRate?: number;
  channels?: number;
  bitsPerSample?: number;
  format?: number;
  byteRate?: number;
  declaredDataBytes?: number;
  leadingChunk?: { id: string; bytes: number };
}

function wav(geometry: Geometry): Uint8Array {
  const sampleRate = geometry.sampleRate ?? 16_000;
  const channels = geometry.channels ?? 1;
  const bits = geometry.bitsPerSample ?? 16;
  const blockAlign = channels * (bits / 8);
  const dataBytes = geometry.frames * blockAlign;
  const lead = geometry.leadingChunk;
  const leadBytes = lead === undefined ? 0 : 8 + lead.bytes + (lead.bytes % 2);
  const buffer = new ArrayBuffer(44 + leadBytes + dataBytes);
  const view = new DataView(buffer);
  const ascii = (offset: number, text: string): void => {
    for (let index = 0; index < text.length; index += 1) view.setUint8(offset + index, text.charCodeAt(index));
  };
  ascii(0, 'RIFF');
  view.setUint32(4, 36 + leadBytes + dataBytes, true);
  ascii(8, 'WAVE');
  let offset = 12;
  if (lead !== undefined) {
    ascii(offset, lead.id);
    view.setUint32(offset + 4, lead.bytes, true);
    offset += leadBytes;
  }
  ascii(offset, 'fmt ');
  view.setUint32(offset + 4, 16, true);
  view.setUint16(offset + 8, geometry.format ?? 1, true);
  view.setUint16(offset + 10, channels, true);
  view.setUint32(offset + 12, sampleRate, true);
  view.setUint32(offset + 16, geometry.byteRate ?? sampleRate * blockAlign, true);
  view.setUint16(offset + 20, blockAlign, true);
  view.setUint16(offset + 22, bits, true);
  ascii(offset + 24, 'data');
  view.setUint32(offset + 28, geometry.declaredDataBytes ?? dataBytes, true);
  return new Uint8Array(buffer);
}

function rejection(audio: Uint8Array): string {
  try {
    wavDurationSeconds(audio);
  } catch (error) {
    expect(error).toBeInstanceOf(ApiError);
    return (error as ApiError).message;
  }
  throw new Error('Expected the payload to be rejected');
}

describe('wavDurationSeconds', () => {
  it('measures frames, not bytes, across sample rates and channel counts', () => {
    expect(wavDurationSeconds(wav({ frames: 32_000 }))).toBe(2);
    expect(wavDurationSeconds(wav({ frames: 48_000 * 3, sampleRate: 48_000, channels: 2 }))).toBe(3);
    expect(wavDurationSeconds(wav({ frames: 8_000, sampleRate: 16_000, bitsPerSample: 24 }))).toBe(0.5);
  });

  it('skips unrelated chunks, including an odd-sized one with its pad byte', () => {
    expect(wavDurationSeconds(wav({ frames: 16_000, leadingChunk: { id: 'LIST', bytes: 5 } }))).toBe(1);
  });

  it('trusts the bytes that arrived when a streamed header declares zero or too much data', () => {
    expect(wavDurationSeconds(wav({ frames: 16_000, declaredDataBytes: 0 }))).toBe(1);
    expect(wavDurationSeconds(wav({ frames: 16_000, declaredDataBytes: 1_000_000 }))).toBe(1);
  });

  it('rejects payloads that are not WAV', () => {
    expect(rejection(new Uint8Array(10))).toBe('Audio body is not a WAV payload');
    const notRiff = wav({ frames: 10 });
    notRiff[0] = 0x58;
    expect(rejection(notRiff)).toBe('Audio body is not a WAV payload');
  });

  it('rejects compressed or self-contradictory PCM geometry', () => {
    expect(rejection(wav({ frames: 10, format: 3 }))).toBe('Audio body has inconsistent PCM geometry');
    expect(rejection(wav({ frames: 10, byteRate: 1 }))).toBe('Audio body has inconsistent PCM geometry');
    expect(rejection(wav({ frames: 10, bitsPerSample: 12 }))).toBe('Audio body has inconsistent PCM geometry');
  });

  it('rejects an empty or partial-frame data chunk', () => {
    expect(rejection(wav({ frames: 0 }))).toBe('Audio body is not a readable WAV payload');
    const partial = wav({ frames: 4, channels: 2 });
    expect(rejection(partial.subarray(0, partial.byteLength - 1))).toBe('Audio body is not a readable WAV payload');
  });
});
