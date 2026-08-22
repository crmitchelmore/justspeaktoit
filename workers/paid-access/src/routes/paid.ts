/**
 * Paid provider proxy routes.
 *
 * The shape of every paid request is the same and deliberately narrow:
 *
 *   1. Authenticate the session.
 *   2. Re-read the entitlement from D1 — the client never asserts entitlement.
 *   3. Claim the request's `Idempotency-Key`, before anything is spent.
 *   4. Resolve the operation to a route via the canonical Best policy — the
 *      client never names a provider, model or cost.
 *   5. Reserve quota for a server-computed upper bound.
 *   6. Call the vendor with the Worker's own credential and an explicit timeout.
 *   7. Finalise quota with the measured amount and append one ledger row.
 *
 * If any step fails, the reservation is released and the claim is dropped so the
 * retry is served. Nothing silently falls back to a different model or to the
 * user's own key.
 */

import {
  ApiError,
  CORRELATION_HEADER,
  jsonResponse,
  readBoundedBytes,
  readJson,
} from '../http.js';
import { providerSecretResolver } from '../env.js';
import { billingPeriod, grantsAccess } from '../entitlement.js';
import { bestRoute, isPaidOperation, policyDocument, type PaidOperation } from '../policy.js';
import { DeepgramProxy, OpenRouterProxy } from '../providers/index.js';
import type { AuthenticatedContext } from '../context.js';
import type { PaidOperationName } from '../data/repository.js';
import type { LiveSessionReconciliation } from '../do/live-session.js';

const MAX_POST_PROCESSING_BODY_BYTES = 256 * 1024;
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

/**
 * Runs a paid operation under its idempotency key.
 *
 * The key is claimed before quota is reserved and before the vendor is called,
 * which is the point: a retry arriving after a client timeout must not buy a
 * second upstream call. A retry that overlaps the original is refused rather
 * than raced; a retry of a finished request is told it already completed, and
 * is charged nothing.
 *
 * That last case deliberately loses the response. Replaying it would mean
 * storing transcripts, and not storing them is the stronger promise: the cost is
 * that a client which loses a response to a timeout must dictate again.
 *
 * A failure drops the claim, so the client's next attempt is served normally
 * instead of being answered as a duplicate for ever.
 */
async function underIdempotencyKey(
  context: AuthenticatedContext,
  input: { idempotencyKey: string; operation: PaidOperationName },
  work: () => Promise<Record<string, unknown>>,
): Promise<Response> {
  const existing = await context.repository.claimRequest({
    userId: context.session.userId,
    idempotencyKey: input.idempotencyKey,
    operation: input.operation,
    correlationId: context.correlationId,
    nowSeconds: context.nowSeconds,
  });

  if (existing !== null) {
    if (existing.operation !== input.operation) {
      throw new ApiError(
        'conflict',
        'That Idempotency-Key was already used for a different operation',
      );
    }
    if (existing.status !== 'completed') {
      throw new ApiError('conflict', 'A request with that Idempotency-Key is still in flight');
    }
    // The work completed and was charged once. The response is not replayed:
    // storing it would make the claims table a store of dictated text, which is
    // exactly what this service promises never to retain. The client is told the
    // request already succeeded so it can say so rather than retrying.
    context.logger.info('paid.idempotent_duplicate', { operation: input.operation });
    throw new ApiError(
      'already_processed',
      'That request has already been processed and was not charged again',
    );
  }

  let payload: Record<string, unknown>;
  try {
    payload = await work();
  } catch (error) {
    await context.repository.releaseRequestClaim({
      userId: context.session.userId,
      idempotencyKey: input.idempotencyKey,
    });
    throw error;
  }

  const body = JSON.stringify(payload);
  await context.repository.completeRequestClaim({
    userId: context.session.userId,
    idempotencyKey: input.idempotencyKey,
    nowSeconds: context.nowSeconds,
  });
  return new Response(body, {
    status: 200,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      [CORRELATION_HEADER]: context.correlationId,
    },
  });
}

/**
 * Records metered usage, insisting the row is actually new.
 *
 * The claim above already guarantees one attempt per idempotency key, so a
 * rejected insert here means the two disagree — an invariant violation worth
 * failing on rather than quietly under-billing.
 */
async function recordMeteredUsage(
  context: AuthenticatedContext,
  input: {
    idempotencyKey: string;
    operation: PaidOperationName;
    provider: string;
    model: string;
    unitKind: 'audio_seconds' | 'tokens';
    units: number;
    billingPeriod: string;
  },
): Promise<void> {
  const recorded = await context.repository.recordUsage({
    userId: context.session.userId,
    idempotencyKey: input.idempotencyKey,
    operation: input.operation,
    provider: input.provider,
    model: input.model,
    unitKind: input.unitKind,
    units: input.units,
    billingPeriod: input.billingPeriod,
    correlationId: context.correlationId,
    nowSeconds: context.nowSeconds,
  });
  if (!recorded) {
    context.logger.error('paid.usage_not_recorded', { operation: input.operation });
    throw new ApiError(
      'conflict',
      'That Idempotency-Key has already been metered for this account',
    );
  }
}

/**
 * The exact duration of a linear-PCM WAV payload.
 *
 * Duration is what gets billed, so it is measured from the payload's own header
 * rather than assumed from its size: a fixed bytes-per-second guess is wrong by
 * a factor of six between 16 kHz mono and 48 kHz stereo, and wrong by an order
 * of magnitude for a compressed container. Nothing we route to reports the
 * duration back, so the payload is the only source of truth — which is why the
 * accepted content types are limited to what this can read.
 */
function wavDurationSeconds(audio: Uint8Array): number {
  const view = new DataView(audio.buffer, audio.byteOffset, audio.byteLength);
  const tag = (offset: number): string =>
    String.fromCharCode(
      view.getUint8(offset),
      view.getUint8(offset + 1),
      view.getUint8(offset + 2),
      view.getUint8(offset + 3),
    );

  if (audio.byteLength < 44 || tag(0) !== 'RIFF' || tag(8) !== 'WAVE') {
    throw new ApiError('bad_request', 'Audio body is not a WAV payload');
  }

  let byteRate: number | null = null;
  let dataBytes: number | null = null;
  let offset = 12;
  while (offset + 8 <= audio.byteLength) {
    const chunkId = tag(offset);
    const chunkSize = view.getUint32(offset + 4, true);
    if (chunkId === 'fmt ' && offset + 24 <= audio.byteLength) {
      byteRate = view.getUint32(offset + 16, true);
    } else if (chunkId === 'data') {
      // A streamed WAV can declare a zero or overlong size; trust what arrived.
      const declared = chunkSize === 0 ? Number.MAX_SAFE_INTEGER : chunkSize;
      dataBytes = Math.min(declared, audio.byteLength - (offset + 8));
      break;
    }
    // Chunks are word-aligned, so an odd size is followed by a pad byte.
    offset += 8 + chunkSize + (chunkSize % 2);
  }

  if (byteRate === null || byteRate <= 0 || dataBytes === null || dataBytes <= 0) {
    throw new ApiError('bad_request', 'Audio body is not a readable WAV payload');
  }
  return dataBytes / byteRate;
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

  // WAV only. The billed quantity is the audio's duration, and a WAV header is
  // the one thing in this path that states it — the upstream returns a
  // transcript, not a duration, and a compressed container's duration cannot be
  // read from its size. Clients send their own key's way anything else.
  const contentType = request.headers.get('content-type') ?? '';
  if (!/^audio\/(wav|x-wav|vnd\.wave)\b/.test(contentType)) {
    throw new ApiError('bad_request', 'Body must be audio/wav');
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
  // Duration is measured from the payload we received, never from a client claim.
  const audioSeconds = Math.max(1, Math.ceil(wavDurationSeconds(audio)));
  const period = billingPeriod(context.nowSeconds);

  return underIdempotencyKey(
    context,
    { idempotencyKey, operation: 'batch_transcription' },
    async () => {
      const reservation = await context.quota.reserve({
        userId: context.session.userId,
        period,
        unitKind: 'audio_seconds',
        units: audioSeconds,
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
          filename: 'audio.wav',
          upstreamModel: route.upstreamModel,
          language,
        });

        await context.quota.finalise({
          userId: context.session.userId,
          reservationId: reservation.reservationId,
          actualUnits: audioSeconds,
          nowSeconds: context.nowSeconds,
        });
        await recordMeteredUsage(context, {
          idempotencyKey,
          operation: 'batch_transcription',
          provider: route.provider,
          model: route.catalogueModelId,
          unitKind: 'audio_seconds',
          units: audioSeconds,
          billingPeriod: period,
        });

        context.logger.info('paid.batch_transcription.completed', {
          provider: route.provider,
          model: route.catalogueModelId,
          audio_seconds: audioSeconds,
        });

        return { text: result.text, model: route.catalogueModelId, provider: route.provider };
      } catch (error) {
        await context.quota.release({
          userId: context.session.userId,
          reservationId: reservation.reservationId,
          nowSeconds: context.nowSeconds,
        });
        throw error;
      }
    },
  );
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

  const text = body.text;
  return underIdempotencyKey(
    context,
    { idempotencyKey, operation: 'post_processing' },
    async () => {
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
          userText: text,
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
        await recordMeteredUsage(context, {
          idempotencyKey,
          operation: 'post_processing',
          provider: route.provider,
          model: route.catalogueModelId,
          unitKind: 'tokens',
          units: measuredTokens,
          billingPeriod: period,
        });

        context.logger.info('paid.post_processing.completed', {
          provider: route.provider,
          model: route.catalogueModelId,
          tokens: measuredTokens,
        });

        return { text: result.text, model: route.catalogueModelId, provider: route.provider };
      } catch (error) {
        await context.quota.release({
          userId: context.session.userId,
          reservationId: reservation.reservationId,
          nowSeconds: context.nowSeconds,
        });
        throw error;
      }
    },
  );
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
          billingPeriod: period,
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

  // The client must echo this back to `/v1/paid/transcribe/live/finalise`;
  // without it the finalise call cannot address this session's Durable Object
  // and the reservation would be held until its lease expired.
  return new Response(response.body, {
    status: 101,
    webSocket: response.webSocket,
    headers: {
      'x-correlation-id': context.correlationId,
      'x-session-id': reservation.reservationId,
    },
  });
}

/**
 * Reconciles a finished live session into the usage ledger.
 *
 * `session_id` is the value returned in the `x-session-id` header when the
 * socket was opened. This route is reconciliation only: the quota reservation
 * was already settled by the Durable Object when the session ended, so a client
 * that never calls this — or that calls it twice — changes nothing about what
 * was metered. The Durable Object hands out its outcome exactly once, which is
 * what stops a replay appending a second ledger row.
 */
export async function handleLiveTranscriptionFinalise(
  request: Request,
  context: AuthenticatedContext,
): Promise<Response> {
  await requirePaidAccess(context);
  const idempotencyKey = requireIdempotencyKey(request);
  const body = await readJson<{ session_id?: unknown }>(request, 4_096);
  if (typeof body.session_id !== 'string' || body.session_id.length > 128) {
    throw new ApiError('bad_request', 'Field session_id is required');
  }

  const sessionId = `${context.session.userId}:${body.session_id}`;
  const stub = context.env.LIVE_SESSION.get(context.env.LIVE_SESSION.idFromName(sessionId));
  const claimResponse = await stub.fetch('https://live.invalid/outcome/reconcile', {
    method: 'POST',
  });
  const claim = (await claimResponse.json()) as LiveSessionReconciliation;
  const outcome = claim.outcome;

  if (outcome === null || outcome.userId !== context.session.userId) {
    throw new ApiError('not_found', 'No finished live session matches that identifier');
  }

  if (claim.alreadyReconciled) {
    return jsonResponse(
      { finalised: true, audio_seconds: outcome.elapsedSeconds, already_reconciled: true },
      { correlationId: context.correlationId },
    );
  }

  const route = bestRoute('live_transcription');
  await recordMeteredUsage(context, {
    idempotencyKey,
    operation: 'live_transcription',
    provider: route.provider,
    model: route.catalogueModelId,
    unitKind: 'audio_seconds',
    units: outcome.elapsedSeconds,
    // The reservation's period, not this moment's. The Durable Object committed
    // the quota against the month the session started in, and a session that
    // spans midnight on the 1st would otherwise book its ledger row to a
    // different month than its quota.
    billingPeriod: outcome.billingPeriod,
  });

  return jsonResponse(
    { finalised: true, audio_seconds: outcome.elapsedSeconds },
    { correlationId: context.correlationId },
  );
}
