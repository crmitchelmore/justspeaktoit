/**
 * Canonical "Best" routing policy.
 *
 * When a user turns on paid access we stop asking them to pick models. This
 * module is the single source of truth for what "Best" means, for all three
 * operations, and it is exposed over the API so the apps can *display* the
 * current choice without being able to *influence* it.
 *
 * Two rules keep this honest:
 *   1. The client never names a provider or model for a paid request. It names
 *      an operation; the server picks.
 *   2. An operation with no supported paid path fails explicitly with
 *      `unsupported_operation`. There is no silent downgrade to a cheaper model
 *      or to the user's own key.
 */

export type PaidOperation = 'live_transcription' | 'batch_transcription' | 'post_processing';

export type PaidProvider = 'openai' | 'openrouter' | 'deepgram';

export interface RoutePolicy {
  readonly operation: PaidOperation;
  readonly provider: PaidProvider;
  /** Catalogue identifier, matching `ModelCatalog` in the Swift clients. */
  readonly catalogueModelId: string;
  /** Identifier sent to the upstream provider. */
  readonly upstreamModel: string;
  readonly unitKind: 'audio_seconds' | 'tokens';
  readonly transport: 'https' | 'websocket';
}

/**
 * The Best paths.
 *
 * Live transcription uses Deepgram Nova-3 streaming: it is the lowest-latency
 * path already supported end-to-end by both apps and it proxies cleanly over a
 * Cloudflare WebSocket. Batch and post-processing go through OpenRouter, which
 * is the existing default for both and needs one upstream credential rather
 * than one per model.
 */
const POLICY: Readonly<Record<PaidOperation, RoutePolicy>> = {
  live_transcription: {
    operation: 'live_transcription',
    provider: 'deepgram',
    catalogueModelId: 'deepgram/nova-3-streaming',
    upstreamModel: 'nova-3',
    unitKind: 'audio_seconds',
    transport: 'websocket',
  },
  batch_transcription: {
    operation: 'batch_transcription',
    provider: 'openrouter',
    catalogueModelId: 'google/gemini-2.0-flash-001',
    upstreamModel: 'google/gemini-2.0-flash-001',
    unitKind: 'audio_seconds',
    transport: 'https',
  },
  post_processing: {
    operation: 'post_processing',
    provider: 'openrouter',
    catalogueModelId: 'openai/gpt-5-mini',
    upstreamModel: 'openai/gpt-5-mini',
    unitKind: 'tokens',
    transport: 'https',
  },
};

export function bestRoute(operation: PaidOperation): RoutePolicy {
  return POLICY[operation];
}

export function allRoutes(): readonly RoutePolicy[] {
  return Object.freeze(Object.values(POLICY));
}

export function isPaidOperation(value: string): value is PaidOperation {
  return value === 'live_transcription' || value === 'batch_transcription'
    || value === 'post_processing';
}

/** Serialisable form returned by `GET /v1/policy`. */
export interface PolicyDocument {
  readonly version: string;
  readonly routes: readonly {
    readonly operation: PaidOperation;
    readonly provider: PaidProvider;
    readonly model: string;
    readonly display_name: string;
    readonly transport: 'https' | 'websocket';
  }[];
}

const DISPLAY_NAMES: Readonly<Record<string, string>> = {
  'deepgram/nova-3-streaming': 'Deepgram Nova-3 (Streaming)',
  'google/gemini-2.0-flash-001': 'Gemini 2.0 Flash',
  'openai/gpt-5-mini': 'GPT-5 Mini',
};

export const POLICY_VERSION = '2026-08-12';

export function policyDocument(): PolicyDocument {
  return {
    version: POLICY_VERSION,
    routes: allRoutes().map((route) => ({
      operation: route.operation,
      provider: route.provider,
      model: route.catalogueModelId,
      display_name: DISPLAY_NAMES[route.catalogueModelId] ?? route.catalogueModelId,
      transport: route.transport,
    })),
  };
}
