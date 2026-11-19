/**
 * Request validation for the paid routes.
 *
 * Pure parsing of what the client sent, with no access checks, quota or
 * spending. `paid.ts` decides when each check runs relative to the claim and
 * the entitlement read; these functions only decide whether input is valid.
 */

import { ApiError } from '../http.js';
import { isPaidOperation, type PaidOperation } from '../policy.js';

/** Caps the caller's post-processing text so its token estimate stays bounded. */
export const MAX_TEXT_CHARACTERS = 100_000;
const MAX_SYSTEM_PROMPT_CHARACTERS = 8_000;
const DEFAULT_TEMPERATURE = 0.2;
const LIVE_SAMPLE_RATES = [8_000, 16_000, 24_000, 44_100, 48_000];

export function requireIdempotencyKey(request: Request): string {
  const key = request.headers.get('idempotency-key');
  if (key === null || !/^[A-Za-z0-9_-]{16,128}$/.test(key)) {
    throw new ApiError(
      'bad_request',
      'An Idempotency-Key header of 16-128 URL-safe characters is required',
    );
  }
  return key;
}

export function requireOperation(value: unknown, expected: PaidOperation): PaidOperation {
  if (typeof value !== 'string' || !isPaidOperation(value) || value !== expected) {
    throw new ApiError('bad_request', `Field operation must be "${expected}"`);
  }
  return value;
}

function languageParameter(url: URL): string | null {
  const language = url.searchParams.get('language');
  if (language !== null && !/^[a-z]{2}(-[A-Za-z0-9]{2,8})?$/.test(language)) {
    throw new ApiError('bad_request', 'Query parameter language is malformed');
  }
  return language;
}

export interface BatchTranscriptionRequest {
  readonly contentType: string;
  readonly language: string | null;
}

/**
 * WAV only. The billed quantity is the audio's duration, and a WAV header is
 * the one thing in this path that states it — the upstream returns a
 * transcript, not a duration, and a compressed container's duration cannot be
 * read from its size. Clients send their own key's way anything else.
 */
export function parseBatchTranscriptionRequest(request: Request): BatchTranscriptionRequest {
  const contentType = request.headers.get('content-type') ?? '';
  if (!/^audio\/(wav|x-wav|vnd\.wave)\b/.test(contentType)) {
    throw new ApiError('bad_request', 'Body must be audio/wav');
  }
  return { contentType, language: languageParameter(new URL(request.url)) };
}

export interface PostProcessingBody {
  operation?: unknown;
  text?: unknown;
  system_prompt?: unknown;
  temperature?: unknown;
}

export interface PostProcessingRequest {
  readonly text: string;
  readonly systemPrompt: string | null;
  readonly temperature: number;
}

/** An oversized prompt or out-of-range temperature falls back to the default. */
export function parsePostProcessingBody(body: PostProcessingBody): PostProcessingRequest {
  requireOperation(body.operation, 'post_processing');
  if (typeof body.text !== 'string' || body.text.length === 0) {
    throw new ApiError('bad_request', 'Field text is required');
  }
  if (body.text.length > MAX_TEXT_CHARACTERS) {
    throw new ApiError('payload_too_large', 'Field text is too long');
  }
  const systemPrompt =
    typeof body.system_prompt === 'string' && body.system_prompt.length <= MAX_SYSTEM_PROMPT_CHARACTERS
      ? body.system_prompt
      : null;
  const temperature =
    typeof body.temperature === 'number' && body.temperature >= 0 && body.temperature <= 2
      ? body.temperature
      : DEFAULT_TEMPERATURE;
  return { text: body.text, systemPrompt, temperature };
}

export interface LiveTranscriptionRequest {
  readonly language: string | null;
  readonly sampleRate: number;
}

export function parseLiveTranscriptionRequest(request: Request): LiveTranscriptionRequest {
  if (request.headers.get('upgrade') !== 'websocket') {
    throw new ApiError('bad_request', 'This endpoint requires a WebSocket upgrade');
  }
  const url = new URL(request.url);
  const language = languageParameter(url);
  const sampleRate = Number.parseInt(url.searchParams.get('sample_rate') ?? '16000', 10);
  if (!LIVE_SAMPLE_RATES.includes(sampleRate)) {
    throw new ApiError('bad_request', 'Query parameter sample_rate is not supported');
  }
  return { language, sampleRate };
}

/** The `x-session-id` value the live socket returned when it opened. */
export function parseLiveFinaliseBody(body: { session_id?: unknown }): string {
  if (typeof body.session_id !== 'string' || body.session_id.length > 128) {
    throw new ApiError('bad_request', 'Field session_id is required');
  }
  return body.session_id;
}
