/**
 * Upstream provider proxies.
 *
 * Vendor API keys live only as Worker secrets and are injected here through a
 * narrowly scoped resolver. Provider modules receive the credential they need
 * and nothing else — no `Env`, no database handle, no session.
 *
 * Requests carry explicit timeouts. Retries are used only for reads that are
 * safe to repeat; a transcription or completion request is attempted once,
 * because a silent retry would bill the vendor twice for one user action.
 */

import { ApiError, fetchWithTimeout, withRetry, isRetryableUpstream } from '../http.js';
import type { SecretResolver } from '../env.js';

export interface BatchTranscriptionRequest {
  readonly audio: Uint8Array;
  readonly contentType: string;
  readonly filename: string;
  readonly upstreamModel: string;
  readonly language: string | null;
}

export interface BatchTranscriptionResult {
  readonly text: string;
  readonly promptTokens: number;
  readonly completionTokens: number;
}

export interface PostProcessingRequest {
  readonly systemPrompt: string | null;
  readonly userText: string;
  readonly upstreamModel: string;
  readonly temperature: number;
}

export interface PostProcessingResult {
  readonly text: string;
  readonly promptTokens: number;
  readonly completionTokens: number;
}

const OPENROUTER_API = 'https://openrouter.ai/api/v1';

interface OpenRouterChoice {
  message?: { content?: string };
}

interface OpenRouterCompletion {
  choices?: OpenRouterChoice[];
  usage?: { prompt_tokens?: number; completion_tokens?: number };
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = '';
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  return btoa(binary);
}

async function readCompletion(response: Response): Promise<PostProcessingResult> {
  if (!response.ok) {
    throw new ApiError('upstream_error', `Provider returned status ${response.status}`);
  }
  const decoded = (await response.json()) as OpenRouterCompletion;
  const text = decoded.choices?.[0]?.message?.content;
  if (typeof text !== 'string') {
    throw new ApiError('upstream_error', 'Provider returned no completion text');
  }
  return {
    text,
    promptTokens: decoded.usage?.prompt_tokens ?? 0,
    completionTokens: decoded.usage?.completion_tokens ?? 0,
  };
}

export class OpenRouterProxy {
  private readonly secrets: SecretResolver;
  private readonly timeoutMs: number;

  constructor(secrets: SecretResolver, timeoutMs: number) {
    this.secrets = secrets;
    this.timeoutMs = timeoutMs;
  }

  private headers(): Record<string, string> {
    return {
      authorization: `Bearer ${this.secrets('OPENROUTER_API_KEY')}`,
      'content-type': 'application/json',
      'http-referer': 'https://justspeaktoit.com',
      'x-title': 'Just Speak to It',
    };
  }

  async transcribe(request: BatchTranscriptionRequest): Promise<BatchTranscriptionResult> {
    const payload = {
      model: request.upstreamModel,
      messages: [
        {
          role: 'user',
          content: [
            {
              type: 'text',
              text:
                'Transcribe the following audio verbatim. Reply with the transcript only, ' +
                'with no commentary, labels or formatting.',
            },
            {
              type: 'input_audio',
              input_audio: {
                data: bytesToBase64(request.audio),
                format: request.filename.endsWith('.m4a') ? 'm4a' : 'wav',
              },
            },
          ],
        },
      ],
      temperature: 0,
    };

    const response = await fetchWithTimeout(
      `${OPENROUTER_API}/chat/completions`,
      { method: 'POST', headers: this.headers(), body: JSON.stringify(payload) },
      this.timeoutMs,
    );
    const completion = await readCompletion(response);
    return {
      text: completion.text,
      promptTokens: completion.promptTokens,
      completionTokens: completion.completionTokens,
    };
  }

  async postProcess(request: PostProcessingRequest): Promise<PostProcessingResult> {
    const messages: { role: string; content: string }[] = [];
    if (request.systemPrompt !== null) {
      messages.push({ role: 'system', content: request.systemPrompt });
    }
    messages.push({ role: 'user', content: request.userText });

    const response = await fetchWithTimeout(
      `${OPENROUTER_API}/chat/completions`,
      {
        method: 'POST',
        headers: this.headers(),
        body: JSON.stringify({
          model: request.upstreamModel,
          messages,
          temperature: request.temperature,
        }),
      },
      this.timeoutMs,
    );
    return readCompletion(response);
  }
}

/**
 * Mints a short-lived Deepgram scoped token for the live WebSocket proxy.
 *
 * Grant creation is an idempotent read-like call, so a bounded retry is safe
 * here — unlike the transcription calls above.
 */
export class DeepgramProxy {
  private readonly secrets: SecretResolver;
  private readonly timeoutMs: number;

  constructor(secrets: SecretResolver, timeoutMs: number) {
    this.secrets = secrets;
    this.timeoutMs = timeoutMs;
  }

  apiKey(): string {
    return this.secrets('DEEPGRAM_API_KEY');
  }

  async verifyCredential(): Promise<boolean> {
    return withRetry(
      async () => {
        const response = await fetchWithTimeout(
          'https://api.deepgram.com/v1/projects',
          { method: 'GET', headers: { authorization: `Token ${this.apiKey()}` } },
          this.timeoutMs,
        );
        if (response.status >= 500) {
          throw new ApiError('upstream_error', 'Deepgram is unavailable');
        }
        return response.ok;
      },
      { attempts: 3, baseDelayMs: 200, isRetryable: isRetryableUpstream },
    );
  }

  /** Builds the upstream streaming URL for the Best live route. */
  streamingUrl(input: { upstreamModel: string; language: string | null; sampleRate: number }): string {
    const url = new URL('wss://api.deepgram.com/v1/listen');
    url.searchParams.set('model', input.upstreamModel);
    url.searchParams.set('encoding', 'linear16');
    url.searchParams.set('sample_rate', String(input.sampleRate));
    url.searchParams.set('channels', '1');
    url.searchParams.set('interim_results', 'true');
    url.searchParams.set('smart_format', 'true');
    if (input.language !== null) {
      url.searchParams.set('language', input.language);
    }
    return url.toString();
  }
}
