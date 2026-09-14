/**
 * Per-request context.
 *
 * Building this once at the router boundary keeps handlers free of binding
 * plumbing and, more importantly, gives every handler the same injected clock
 * so time-dependent behaviour (expiry, grace, leases) is testable.
 */

import { loadConfig, requireSecret, type Config, type Env } from './env.js';
import { Repository } from './data/repository.js';
import { QuotaClient } from './quota.js';
import { ApiError, correlationIdFrom, requestLogger } from './http.js';
import { bearerToken, verifyAccessToken, type SessionClaims } from './auth/session.js';
import type { Logger } from './logging.js';

export interface RequestContext {
  readonly env: Env;
  readonly config: Config;
  readonly repository: Repository;
  readonly quota: QuotaClient;
  readonly logger: Logger;
  readonly correlationId: string;
  readonly nowSeconds: number;
  readonly nowMs: number;
}

export function createContext(request: Request, env: Env): RequestContext {
  const correlationId = correlationIdFrom(request);
  const config = loadConfig(env);
  const nowMs = Date.now();

  return {
    env,
    config,
    repository: new Repository(env.DB),
    quota: new QuotaClient(env.QUOTA, {
      monthlyAudioSeconds: config.planMonthlySeconds,
      monthlyTokens: config.planMonthlyPostProcessTokens,
      maxConcurrentSessions: config.maxConcurrentSessions,
      leaseSeconds: config.maxLiveSessionSeconds + 60,
    }),
    logger: requestLogger(request, correlationId),
    correlationId,
    nowSeconds: Math.floor(nowMs / 1_000),
    nowMs,
  };
}

export interface AuthenticatedContext extends RequestContext {
  readonly session: SessionClaims;
}

/**
 * Authenticates a request.
 *
 * Rejection is deliberately uniform — an expired token, a forged token and a
 * token for a disabled account all produce the same `unauthorized` response, so
 * the endpoint cannot be used to probe account state.
 */
export async function authenticate(
  request: Request,
  context: RequestContext,
): Promise<AuthenticatedContext> {
  const token = bearerToken(request);
  if (token === null) {
    throw new ApiError('unauthorized', 'A bearer access token is required');
  }

  let session: SessionClaims;
  try {
    session = await verifyAccessToken(requireSecret(context.env, 'SESSION_SIGNING_KEY'), token);
  } catch {
    throw new ApiError('unauthorized', 'Access token is not valid');
  }

  const user = await context.repository.findUserById(session.userId);
  if (user === null || user.disabledAt !== null) {
    throw new ApiError('unauthorized', 'Access token is not valid');
  }
  if (!(await context.repository.isAuthSessionActive(session.sessionId, context.nowSeconds))) {
    // Sign-out and refresh reuse detection revoke the session row; an access
    // token minted before that must stop working immediately.
    throw new ApiError('unauthorized', 'Access token is not valid');
  }
  if (user.role !== session.role) {
    // Role changed since the token was minted; force a refresh rather than
    // honouring stale claims.
    throw new ApiError('unauthorized', 'Access token is not valid');
  }

  return { ...context, session, logger: context.logger.child({ user_id: session.userId }) };
}
