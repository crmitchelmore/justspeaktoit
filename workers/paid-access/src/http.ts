/**
 * HTTP plumbing: correlation IDs, typed errors, bounded body reads and
 * timeouts. Every response leaving the Worker carries the correlation id so a
 * user-visible failure can be traced without asking for any request content.
 */

import { createLogger, type Logger } from './logging.js';

export const CORRELATION_HEADER = 'x-correlation-id';

export type ErrorCode =
  | 'bad_request'
  | 'unauthorized'
  | 'forbidden'
  | 'not_found'
  | 'conflict'
  | 'payload_too_large'
  | 'quota_exceeded'
  | 'too_many_sessions'
  | 'unsupported_operation'
  | 'entitlement_required'
  | 'paid_routing_disabled'
  | 'upstream_error'
  | 'upstream_timeout'
  | 'internal_error';

const STATUS_BY_CODE: Record<ErrorCode, number> = {
  bad_request: 400,
  unauthorized: 401,
  forbidden: 403,
  not_found: 404,
  conflict: 409,
  payload_too_large: 413,
  quota_exceeded: 429,
  too_many_sessions: 429,
  unsupported_operation: 422,
  entitlement_required: 402,
  paid_routing_disabled: 503,
  upstream_error: 502,
  upstream_timeout: 504,
  internal_error: 500,
};

export class ApiError extends Error {
  readonly code: ErrorCode;
  readonly detail: string | undefined;

  constructor(code: ErrorCode, message: string, detail?: string) {
    super(message);
    this.name = 'ApiError';
    this.code = code;
    this.detail = detail;
  }

  get status(): number {
    return STATUS_BY_CODE[this.code];
  }
}

export function correlationIdFrom(request: Request): string {
  const supplied = request.headers.get(CORRELATION_HEADER);
  // Client-supplied ids are echoed for cross-process tracing but constrained so
  // they cannot be used to inject content into logs.
  if (supplied && /^[A-Za-z0-9_-]{8,64}$/.test(supplied)) {
    return supplied;
  }
  return crypto.randomUUID();
}

export function requestLogger(request: Request, correlationId: string): Logger {
  const url = new URL(request.url);
  return createLogger(correlationId, { method: request.method, path: url.pathname });
}

export function jsonResponse(
  body: unknown,
  init: { status?: number; correlationId: string; headers?: Record<string, string> },
): Response {
  return new Response(JSON.stringify(body), {
    status: init.status ?? 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      [CORRELATION_HEADER]: init.correlationId,
      ...(init.headers ?? {}),
    },
  });
}

export function errorResponse(error: ApiError, correlationId: string): Response {
  return jsonResponse(
    {
      error: {
        code: error.code,
        message: error.message,
        ...(error.detail ? { detail: error.detail } : {}),
        correlation_id: correlationId,
      },
    },
    { status: error.status, correlationId },
  );
}

/**
 * Reads a JSON body with a hard byte ceiling. Streaming the body and counting
 * bytes means an oversized upload is rejected without ever being buffered
 * whole, which matters because these endpoints accept audio.
 */
export async function readJson<T>(request: Request, maxBytes: number): Promise<T> {
  const raw = await readBoundedText(request, maxBytes);
  try {
    return JSON.parse(raw) as T;
  } catch {
    throw new ApiError('bad_request', 'Request body is not valid JSON');
  }
}

export async function readBoundedText(request: Request, maxBytes: number): Promise<string> {
  const bytes = await readBoundedBytes(request, maxBytes);
  return new TextDecoder().decode(bytes);
}

export async function readBoundedBytes(request: Request, maxBytes: number): Promise<Uint8Array> {
  const declared = request.headers.get('content-length');
  if (declared !== null) {
    const length = Number.parseInt(declared, 10);
    if (Number.isFinite(length) && length > maxBytes) {
      throw new ApiError('payload_too_large', `Request body exceeds ${maxBytes} bytes`);
    }
  }

  const body = request.body;
  if (body === null) {
    return new Uint8Array(0);
  }

  const reader = body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  for (;;) {
    const chunk: ReadableStreamReadResult<Uint8Array> = await reader.read();
    if (chunk.done) break;
    const value = chunk.value;
    if (value === undefined) continue;
    total += value.byteLength;
    if (total > maxBytes) {
      await reader.cancel().catch(() => undefined);
      throw new ApiError('payload_too_large', `Request body exceeds ${maxBytes} bytes`);
    }
    chunks.push(value);
  }

  const merged = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    merged.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return merged;
}

/**
 * Bounded retry with jittered backoff.
 *
 * Only idempotent upstream reads should use `attempts > 1`; anything that could
 * charge a vendor twice must be called with the default single attempt.
 */
export async function withRetry<T>(
  operation: (attempt: number) => Promise<T>,
  options: { attempts: number; baseDelayMs: number; isRetryable: (error: unknown) => boolean },
): Promise<T> {
  let lastError: unknown;
  for (let attempt = 1; attempt <= options.attempts; attempt += 1) {
    try {
      return await operation(attempt);
    } catch (error) {
      lastError = error;
      if (attempt === options.attempts || !options.isRetryable(error)) {
        throw error;
      }
      const jitter = Math.floor(Math.random() * options.baseDelayMs);
      await sleep(options.baseDelayMs * 2 ** (attempt - 1) + jitter);
    }
  }
  throw lastError;
}

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Wraps `fetch` with an explicit deadline. Workers have no default timeout. */
export async function fetchWithTimeout(
  input: RequestInfo,
  init: RequestInit,
  timeoutMs: number,
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(input, { ...init, signal: controller.signal });
  } catch (error) {
    if (error instanceof Error && error.name === 'AbortError') {
      throw new ApiError('upstream_timeout', 'Upstream provider did not respond in time');
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

export function isRetryableUpstream(error: unknown): boolean {
  if (error instanceof ApiError) {
    return error.code === 'upstream_timeout' || error.code === 'upstream_error';
  }
  return false;
}
