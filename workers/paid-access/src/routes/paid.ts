/**
 * Paid provider proxy routes.
 *
 * The shape of every paid request is the same and deliberately narrow:
 *
 *   1. Authenticate the session.
 *   2. Re-read the entitlement from D1 — the client never asserts entitlement.
 *   3. Resolve the operation to a route via the canonical Best policy — the
 *      client never names a provider, model or cost.
 *   4. Reserve quota for a server-computed upper bound.
 *   5. Call the vendor with the Worker's own credential and an explicit timeout.
 *   6. Finalise quota with the measured amount and append one ledger row.
 *
 * If any step fails, the reservation is released. Nothing silently falls back to
 * a different model or to the user's own key.
 */

import {
  ApiError,
  jsonResponse,
  readBoundedBytes,
  readJson,
} from '../http.js';
import { providerSecretResolver } from '../env.js';
import { billingPeriod, grantsAccess } from '../entitlement.js';
import { bestRoute, isPaidOperation, policyDocument, type PaidOperation } from '../policy.js';
import { DeepgramProxy, OpenRouterProxy } from '../providers/index.js';
import type { AuthenticatedContext } from '../context.js';
import type { LiveSessionOutcome } from '../do/live-session.js';

const MAX_POST_PROCESSING_BODY_BYTES = 256 * 1024;
/** WAV at 16 kHz mono is 32 kB per second; used to bound a reservation. */
const ASSUMED_BYTES_PER_AUDIO_SECOND = 32_000;
const MAX_TEXT_CHARACTERS = 100_000;
/** Rough characters-per-token ratio, used only to size the quota reservation. */
const CHARACTERS_PER_TOKEN = 4;
/**
 * Fixed allowance covering the model's own overhead and the completion, so the
 * reservation is a genuine upper bound even for a one-line transcript. Getting
 * this wrong the other way would silently under-bill short requests.
 */
const POST_PROCESSING_TOKEN_OVERHEAD = 1_024;

/**
 * Asserts the caller may use paid routing right now.
 *
 * `PAID_ROUTING_DISABLED` is the incident kill switch: it fails paid requests
 * closed without revoking anybody's entitlement, so clients fall back to their
 * own keys or local models and recovery is a single config change.
 */
async function requirePaidAccess(context: AuthenticatedContext): Promise<void> {
  if (context.config.paidRoutingDisabled) {
    throw new ApiError('paid_routing_disabled', 'Paid routing is temporarily disabled');
  }
  const entitlement = await context.repository.findEntitlement(context.session.userId);
  if (!grantsAccess(entitlement, context.nowSeconds)) {
    await context.repository.recordAudit({
      userId: context.session.userId,
      actor: 'user',
      action: 'paid.access_check',
      outcome: 'denied',
      detail: entitlement?.status ?? 'none',
      correlationId: context.correlationId,
      nowSeconds: context.nowSeconds,
    });
    throw new ApiError('entitlement_required', 'An active subscription is required');
  }
}

function requireOperation(value: unknown, expected: PaidOperation): PaidOperation {
  if (typeof value !== 'string' || !isPaidOperation(value) || value !== expected) {
    throw new ApiError('bad_request', `Field operation must be "${expected}"`);
  }
  return value;
}

function requireIdempotencyKey(request: Request): string {
  const key = request.headers.get('idempotency-key');
  if (key === null || !/^[A-Za-z0-9_-]{16,128}$/.test(key)) {
    throw new ApiError(
      'bad_request',
      'An Idempotency-Key header of 16-128 URL-safe characters is required',
    );
  }
  return key;
}

export function handlePolicy(context: AuthenticatedContext): Response {
  return jsonResponse(policyDocument(), { correlationId: context.correlationId });
}

// ---------------------------------------------------------------------------
// Batch transcription
// ---------------------------------------------------------------------------

export async function handleBatchTranscription(
  request: Request,
  context: AuthenticatedContext,
): Promise<Response> {
  await requirePaidAccess(context);
  const idempotencyKey = requireIdempotencyKey(request);

  const contentType = request.headers.get('content-type') ?? '';
  if (!/^audio\/(wav|x-wav|mp4|m4a|mpeg)\b/.test(contentType)) {
    throw new ApiError('bad_request', 'Body must be audio/wav, audio/mp4 or audio/mpeg');
  }
  const language = new URL(request.url).searchParams.get('language');
  if (language !== null && !/^[a-z]{2}(-[A-Za-z0-9]{2,8})?$/.test(language)) {
    throw new ApiError('bad_request', 'Query parameter language is malformed');
  }

  const audio = await readBoundedBytes(request, context.config.maxRequestBytes);
  if (audio.byteLength === 0) {
    throw new ApiError('bad_request', 'Audio body is empty');
  }

  const route = bestRoute('batch_transcription');
  // Duration is derived from the payload we received, never from a client claim.
  const estimatedSeconds = Math.max(1, Math.ceil(audio.byteLength / ASSUMED_BYTES_PER_AUDIO_SECOND));
  const period = billingPeriod(context.nowSeconds);

  const reservation = await context.quota.reserve({
    userId: context.session.userId,
    period,
    unitKind: 'audio_seconds',
    units: estimatedSeconds,
    countsAsSession: false,
    nowSeconds: context.nowSeconds,
  });

  try {
    const proxy = new OpenRouterProxy(
      providerSecretResolver(context.env, ['OPENROUTER_API_KEY']),
      context.config.upstreamTimeoutMs,
    );
    const result = await proxy.transcribe({
      audio,
      contentType,
      filename: contentType.includes('mp4') || contentType.includes('m4a') ? 'audio.m4a' : 'audio.wav',
      upstreamModel: route.upstreamModel,
      language,
    });

    await context.quota.finalise({
      userId: context.session.userId,
      reservationId: reservation.reservationId,
      actualUnits: estimatedSeconds,
      nowSeconds: context.nowSeconds,
    });
    await context.repository.recordUsage({
      userId: context.session.userId,
      idempotencyKey,
      operation: 'batch_transcription',
      provider: route.provider,
      model: route.catalogueModelId,
      unitKind: 'audio_seconds',
      units: estimatedSeconds,
      billingPeriod: period,
      correlationId: context.correlationId,
      nowSeconds: context.nowSeconds,
    });

    context.logger.info('paid.batch_transcription.completed', {
      provider: route.provider,
      model: route.catalogueModelId,
      audio_seconds: estimatedSeconds,
    });

    return jsonResponse(
      { text: result.text, model: route.catalogueModelId, provider: route.provider },
      { correlationId: context.correlationId },
    );
  } catch (error) {
    await context.quota.release({
      userId: context.session.userId,
      reservationId: reservation.reservationId,
      nowSeconds: context.nowSeconds,
    });
    throw error;
  }
}

// ---------------------------------------------------------------------------
// Post-processing
// ---------------------------------------------------------------------------

interface PostProcessingBody {
  operation?: unknown;
  text?: unknown;
  system_prompt?: unknown;
  temperature?: unknown;
}

export async function handlePostProcessing(
  request: Request,
  context: AuthenticatedContext,
): Promise<Response> {
  await requirePaidAccess(context);
  const idempotencyKey = requireIdempotencyKey(request);

  const body = await readJson<PostProcessingBody>(request, MAX_POST_PROCESSING_BODY_BYTES);
  requireOperation(body.operation, 'post_processing');

  if (typeof body.text !== 'string' || body.text.length === 0) {
    throw new ApiError('bad_request', 'Field text is required');
  }
  if (body.text.length > MAX_TEXT_CHARACTERS) {
    throw new ApiError('payload_too_large', 'Field text is too long');
  }
  const systemPrompt =
    typeof body.system_prompt === 'string' && body.system_prompt.length <= 8_000
      ? body.system_prompt
      : null;
  const temperature =
    typeof body.temperature === 'number' && body.temperature >= 0 && body.temperature <= 2
      ? body.temperature
      : 0.2;

  const route = bestRoute('post_processing');
  const period = billingPeriod(context.nowSeconds);
  const estimatedTokens =
    POST_PROCESSING_TOKEN_OVERHEAD +
    Math.ceil(((body.text.length + (systemPrompt?.length ?? 0)) * 3) / CHARACTERS_PER_TOKEN);

  const reservation = await context.quota.reserve({
    userId: context.session.userId,
    period,
    unitKind: 'tokens',
    units: estimatedTokens,
    countsAsSession: false,
    nowSeconds: context.nowSeconds,
  });

  try {
    const proxy = new OpenRouterProxy(
      providerSecretResolver(context.env, ['OPENROUTER_API_KEY']),
      context.config.upstreamTimeoutMs,
    );
    const result = await proxy.postProcess({
      systemPrompt,
      userText: body.text,
      upstreamModel: route.upstreamModel,
      temperature,
    });

    // Cost comes from the provider's usage report, never from the client. The
    // reservation caps it, so the ledger and the quota always agree.
    const measuredTokens = Math.min(
      Math.max(1, result.promptTokens + result.completionTokens),
      estimatedTokens,
    );

    await context.quota.finalise({
      userId: context.session.userId,
      reservationId: reservation.reservationId,
      actualUnits: measuredTokens,
      nowSeconds: context.nowSeconds,
    });
    await context.repository.recordUsage({
      userId: context.session.userId,
      idempotencyKey,
      operation: 'post_processing',
      provider: route.provider,
      model: route.catalogueModelId,
      unitKind: 'tokens',
      units: measuredTokens,
      billingPeriod: period,
      correlationId: context.correlationId,
      nowSeconds: context.nowSeconds,
    });

    context.logger.info('paid.post_processing.completed', {
      provider: route.provider,
      model: route.catalogueModelId,
      tokens: measuredTokens,
    });

    return jsonResponse(
      { text: result.text, model: route.catalogueModelId, provider: route.provider },
      { correlationId: context.correlationId },
    );
  } catch (error) {
    await context.quota.release({
      userId: context.session.userId,
      reservationId: reservation.reservationId,
      nowSeconds: context.nowSeconds,
    });
    throw error;
  }
}

// ---------------------------------------------------------------------------
// Live transcription
// ---------------------------------------------------------------------------

/**
 * Opens a proxied live transcription WebSocket.
 *
 * Quota is reserved for the maximum session length up front and reconciled to
 * the measured duration when the session ends, so a user cannot start more
 * concurrent sessions than the plan allows and cannot exceed the monthly
 * allowance by never disconnecting.
 */
export async function handleLiveTranscription(
  request: Request,
  context: AuthenticatedContext,
): Promise<Response> {
  await requirePaidAccess(context);

  if (request.headers.get('upgrade') !== 'websocket') {
    throw new ApiError('bad_request', 'This endpoint requires a WebSocket upgrade');
  }

  const url = new URL(request.url);
  const language = url.searchParams.get('language');
  if (language !== null && !/^[a-z]{2}(-[A-Za-z0-9]{2,8})?$/.test(language)) {
    throw new ApiError('bad_request', 'Query parameter language is malformed');
  }
  const sampleRate = Number.parseInt(url.searchParams.get('sample_rate') ?? '16000', 10);
  if (![8_000, 16_000, 24_000, 44_100, 48_000].includes(sampleRate)) {
    throw new ApiError('bad_request', 'Query parameter sample_rate is not supported');
  }

  const route = bestRoute('live_transcription');
  if (route.transport !== 'websocket') {
    throw new ApiError('unsupported_operation', 'Live transcription has no paid streaming route');
  }

  const period = billingPeriod(context.nowSeconds);
  const reservation = await context.quota.reserve({
    userId: context.session.userId,
    period,
    unitKind: 'audio_seconds',
    units: context.config.maxLiveSessionSeconds,
    countsAsSession: true,
    nowSeconds: context.nowSeconds,
  });

  const deepgram = new DeepgramProxy(
    providerSecretResolver(context.env, ['DEEPGRAM_API_KEY']),
    context.config.liveUpstreamTimeoutMs,
  );

  const sessionId = `${context.session.userId}:${reservation.reservationId}`;
  const stub = context.env.LIVE_SESSION.get(context.env.LIVE_SESSION.idFromName(sessionId));

  let response: Response;
  try {
    response = await stub.fetch('https://live.invalid/', {
      headers: {
        upgrade: 'websocket',
        'x-session-init': JSON.stringify({
          userId: context.session.userId,
          reservationId: reservation.reservationId,
          upstreamUrl: deepgram.streamingUrl({
            upstreamModel: route.upstreamModel,
            language,
            sampleRate,
          }),
          upstreamProtocolHeader: `Token ${deepgram.apiKey()}`,
          maxSessionSeconds: context.config.maxLiveSessionSeconds,
          connectTimeoutMs: context.config.liveUpstreamTimeoutMs,
          correlationId: context.correlationId,
        }),
      },
    });
  } catch (error) {
    await context.quota.release({
      userId: context.session.userId,
      reservationId: reservation.reservationId,
      nowSeconds: context.nowSeconds,
    });
    throw error;
  }

  if (response.status !== 101) {
    await context.quota.release({
      userId: context.session.userId,
      reservationId: reservation.reservationId,
      nowSeconds: context.nowSeconds,
    });
    throw new ApiError('upstream_error', 'Live transcription provider is unavailable');
  }

  context.logger.info('paid.live_transcription.started', {
    provider: route.provider,
    model: route.catalogueModelId,
  });

  return new Response(response.body, {
    status: 101,
    webSocket: response.webSocket,
    headers: { 'x-correlation-id': context.correlationId },
  });
}

/**
 * Reconciles a finished live session.
 *
 * The client calls this when its socket closes; the Durable Object is the
 * source of truth for the measured duration, so a client that never calls it
 * simply keeps its reservation until the lease expires — it can never under-report.
 */
export async function handleLiveTranscriptionFinalise(
  request: Request,
  context: AuthenticatedContext,
): Promise<Response> {
  const idempotencyKey = requireIdempotencyKey(request);
  const body = await readJson<{ session_id?: unknown }>(request, 4_096);
  if (typeof body.session_id !== 'string' || body.session_id.length > 128) {
    throw new ApiError('bad_request', 'Field session_id is required');
  }

  const sessionId = `${context.session.userId}:${body.session_id}`;
  const stub = context.env.LIVE_SESSION.get(context.env.LIVE_SESSION.idFromName(sessionId));
  const outcomeResponse = await stub.fetch('https://live.invalid/outcome');
  const outcome = (await outcomeResponse.json()) as LiveSessionOutcome | null;

  if (outcome === null || outcome.userId !== context.session.userId) {
    throw new ApiError('not_found', 'No finished live session matches that identifier');
  }

  const route = bestRoute('live_transcription');
  await context.quota.finalise({
    userId: context.session.userId,
    reservationId: outcome.reservationId,
    actualUnits: outcome.elapsedSeconds,
    nowSeconds: context.nowSeconds,
  });
  await context.repository.recordUsage({
    userId: context.session.userId,
    idempotencyKey,
    operation: 'live_transcription',
    provider: route.provider,
    model: route.catalogueModelId,
    unitKind: 'audio_seconds',
    units: outcome.elapsedSeconds,
    billingPeriod: billingPeriod(context.nowSeconds),
    correlationId: context.correlationId,
    nowSeconds: context.nowSeconds,
  });

  return jsonResponse(
    { finalised: true, audio_seconds: outcome.elapsedSeconds },
    { correlationId: context.correlationId },
  );
}
