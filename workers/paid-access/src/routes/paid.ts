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
 * Batch/post operations retain metadata-only settlement state before dispatch.
 * Only proven pre-dispatch refusal permits fallback; unknown outcomes retain
 * an allowance hold and never automatically dispatch or charge an estimate.
 */

import {
  ApiError,
  jsonResponse,
  readBoundedBytes,
  readJson,
} from '../http.js';
import { claimOperation, runOperation, SETTLEMENT_HEADER, SETTLEMENT_VERSION } from './settlement.js';
import { providerSecretResolver } from '../env.js';
import { describeError } from '../logging.js';
import { billingPeriod, grantsAccess } from '../entitlement.js';
import { bestRoute, policyDocument } from '../policy.js';
import { wavDurationSeconds } from '../audio/wav.js';
import {
  parseBatchTranscriptionRequest,
  parseLiveFinaliseBody,
  parseLiveTranscriptionRequest,
  parsePostProcessingBody,
  requireIdempotencyKey,
  type PostProcessingBody,
} from './paid-requests.js';
import { DeepgramProxy, OpenRouterProxy } from '../providers/index.js';
import type { AuthenticatedContext } from '../context.js';
import type { PaidOperationName } from '../data/repository.js';
import type { LiveSessionReconciliation } from '../do/live-session.js';

const MAX_POST_PROCESSING_BODY_BYTES = 256 * 1024;
// UTF-8 bytes conservatively bound prompt tokens for the routed byte tokenizer;
// fixed overhead covers message framing. Completion spending is capped upstream.
const POST_PROCESSING_TOKEN_OVERHEAD = 1_024;
const MAX_OUTPUT_TOKENS = 4_096;

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
  const entitlement = await context.repository.entitlements.findEntitlement(context.session.userId);
  if (!grantsAccess(entitlement, context.nowSeconds)) {
    await context.repository.audit.recordAudit({
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

async function requireNewOperationAccess(request: Request, context: AuthenticatedContext): Promise<void> {
  if (request.headers.get(SETTLEMENT_HEADER) !== SETTLEMENT_VERSION) {
    throw new ApiError('paid_routing_disabled', 'This client cannot safely settle paid operations');
  }
  await requirePaidAccess(context);
}

/**
 * Releases the claim of an operation that failed before dispatch, so the key can be retried. If
 * the receipt or release cannot be read, the claim is kept (operational claim expiry never deletes
 * a DO receipt) and the unknown outcome is logged with metadata only, for reconciliation.
 */
async function releaseUnstartedClaim(context: AuthenticatedContext, key: string): Promise<void> {
  let step: 'receipt_lookup' | 'claim_release' = 'receipt_lookup';
  try {
    const receipt = await context.quota.operationReceipt(context.session.userId, key, Math.floor(Date.now() / 1000));
    if (receipt !== null) return;
    step = 'claim_release';
    await context.repository.usage.releaseRequestClaim({ userId: context.session.userId, idempotencyKey: key });
  } catch (error) {
    context.logger.warn('paid.claim_release_unknown', { step, error: describeError(error) });
  }
}

export function handlePolicy(context: AuthenticatedContext): Response {
  return jsonResponse(policyDocument(), { correlationId: context.correlationId });
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
  const recorded = await context.repository.usage.recordUsage({
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

// ---------------------------------------------------------------------------
// Batch transcription
// ---------------------------------------------------------------------------

export async function handleBatchTranscription(
  request: Request,
  context: AuthenticatedContext,
): Promise<Response> {
  const idempotencyKey = requireIdempotencyKey(request);
  await claimOperation(request, context, idempotencyKey, 'batch_transcription');
  try {
    await requireNewOperationAccess(request, context);
    const { contentType, language } = parseBatchTranscriptionRequest(request);

    const audio = await readBoundedBytes(request, context.config.maxRequestBytes);
    if (audio.byteLength === 0) {
      throw new ApiError('bad_request', 'Audio body is empty');
    }

    const route = bestRoute('batch_transcription');
    // Duration is measured from the payload we received, never from a client claim.
    const audioSeconds = Math.max(1, Math.ceil(wavDurationSeconds(audio)));
    const period = billingPeriod(context.nowSeconds);

    return jsonResponse(await runOperation(request, context, {
      idempotencyKey, operation: 'batch_transcription', provider: route.provider,
      model: route.catalogueModelId, unitKind: 'audio_seconds', period, units: audioSeconds,
    }, async () => {
      const proxy = new OpenRouterProxy(providerSecretResolver(context.env, ['OPENROUTER_API_KEY']),
        context.config.upstreamTimeoutMs);
      const result = await proxy.transcribe({ audio, contentType, filename: 'audio.wav',
        upstreamModel: route.upstreamModel, language });
      return { payload: { text: result.text, model: route.catalogueModelId, provider: route.provider }, units: audioSeconds };
    }), { correlationId: context.correlationId });
  } catch (error) {
    await releaseUnstartedClaim(context, idempotencyKey);
    throw error;
  }
}

// ---------------------------------------------------------------------------
// Post-processing
// ---------------------------------------------------------------------------

export async function handlePostProcessing(
  request: Request,
  context: AuthenticatedContext,
): Promise<Response> {
  const idempotencyKey = requireIdempotencyKey(request);
  await claimOperation(request, context, idempotencyKey, 'post_processing');
  try {
    await requireNewOperationAccess(request, context);
    const { text, systemPrompt, temperature } = parsePostProcessingBody(
      await readJson<PostProcessingBody>(request, MAX_POST_PROCESSING_BODY_BYTES),
    );

    const route = bestRoute('post_processing');
    const period = billingPeriod(context.nowSeconds);
    const estimatedTokens =
      POST_PROCESSING_TOKEN_OVERHEAD +
      new TextEncoder().encode(text + (systemPrompt ?? "")).byteLength + MAX_OUTPUT_TOKENS;

    return jsonResponse(await runOperation(request, context, {
      idempotencyKey, operation: 'post_processing', provider: route.provider,
      model: route.catalogueModelId, unitKind: 'tokens', period, units: estimatedTokens,
    }, async () => {
      const proxy = new OpenRouterProxy(providerSecretResolver(context.env, ['OPENROUTER_API_KEY']),
        context.config.upstreamTimeoutMs);
      const result = await proxy.postProcess({ systemPrompt, userText: text,
        upstreamModel: route.upstreamModel, temperature, maxOutputTokens: MAX_OUTPUT_TOKENS });
      const reported = result.promptTokens + result.completionTokens;
      const units = result.usageMeasured && Number.isSafeInteger(reported) && reported >= 0 ? reported : null;
      return { payload: { text: result.text, model: route.catalogueModelId, provider: route.provider }, units };
    }), { correlationId: context.correlationId });
  } catch (error) {
    await releaseUnstartedClaim(context, idempotencyKey);
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
  const { language, sampleRate } = parseLiveTranscriptionRequest(request);

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
  const clientSessionId = parseLiveFinaliseBody(await readJson<{ session_id?: unknown }>(request, 4_096));

  const sessionId = `${context.session.userId}:${clientSessionId}`;
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
