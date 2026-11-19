/**
 * Authentication routes.
 *
 * Sign in with Apple is the only identity source, and it is shared across
 * channels and devices: the same Apple subject signing in on a Mac direct
 * download and on iPhone resolves to one user row and therefore one
 * entitlement, whichever channel paid for it.
 */

import { ApiError, jsonResponse, readJson } from '../http.js';
import { verifyAppleIdentityToken } from '../auth/apple-identity.js';
import {
  createRefreshToken,
  issueAccessToken,
  refreshTokenHash,
  type UserRole,
} from '../auth/session.js';
import { requireSecret } from '../env.js';
import { effectiveStatus } from '../entitlement.js';
import type { RequestContext, AuthenticatedContext } from '../context.js';

const MAX_AUTH_BODY_BYTES = 16 * 1024;

interface AppleSignInBody {
  identity_token?: unknown;
  nonce?: unknown;
  device_label?: unknown;
}

interface RefreshBody {
  refresh_token?: unknown;
}

function readString(value: unknown, field: string, maxLength: number): string {
  if (typeof value !== 'string' || value.length === 0 || value.length > maxLength) {
    throw new ApiError('bad_request', `Field ${field} is missing or malformed`);
  }
  return value;
}

async function issueSession(
  context: RequestContext,
  user: { id: string; role: UserRole },
  deviceLabel: string | null,
): Promise<Response> {
  const signingKey = requireSecret(context.env, 'SESSION_SIGNING_KEY');
  const refresh = await createRefreshToken();

  const sessionId = await context.repository.users.createAuthSession({
    userId: user.id,
    refreshTokenHash: refresh.hash,
    deviceLabel,
    createdAt: context.nowSeconds,
    expiresAt: context.nowSeconds + context.config.refreshTtlSeconds,
  });

  const access = await issueAccessToken(
    signingKey,
    { userId: user.id, sessionId, role: user.role },
    context.config.sessionTtlSeconds,
    context.nowSeconds,
  );

  const entitlement = await context.repository.entitlements.ensureEntitlement(user.id, context.nowSeconds);

  return jsonResponse(
    {
      access_token: access.token,
      access_token_expires_at: access.expiresAt,
      refresh_token: refresh.token,
      refresh_token_expires_at: context.nowSeconds + context.config.refreshTtlSeconds,
      user_id: user.id,
      role: user.role,
      entitlement_status: effectiveStatus(entitlement, context.nowSeconds),
    },
    { correlationId: context.correlationId },
  );
}

export async function handleAppleSignIn(
  request: Request,
  context: RequestContext,
): Promise<Response> {
  const body = await readJson<AppleSignInBody>(request, MAX_AUTH_BODY_BYTES);
  const identityToken = readString(body.identity_token, 'identity_token', 8_192);
  const nonce = readString(body.nonce, 'nonce', 256);
  const deviceLabel =
    typeof body.device_label === 'string' && body.device_label.length <= 64
      ? body.device_label
      : null;

  let claims;
  try {
    claims = await verifyAppleIdentityToken(identityToken, nonce, {
      audiences: context.config.appleIdentityAudiences,
    });
  } catch {
    context.logger.warn('auth.apple.rejected');
    await context.repository.audit.recordAudit({
      userId: null,
      actor: 'user',
      action: 'auth.apple.sign_in',
      outcome: 'denied',
      detail: 'identity_token_rejected',
      correlationId: context.correlationId,
      nowSeconds: context.nowSeconds,
    });
    throw new ApiError('unauthorized', 'Apple identity token could not be verified');
  }

  const user = await context.repository.users.upsertUserByAppleSub(
    claims.subject,
    claims.emailVerified ? claims.email : null,
    context.nowSeconds,
  );
  if (user.disabledAt !== null) {
    throw new ApiError('forbidden', 'This account is disabled');
  }

  await context.repository.audit.recordAudit({
    userId: user.id,
    actor: 'user',
    action: 'auth.apple.sign_in',
    outcome: 'allowed',
    detail: null,
    correlationId: context.correlationId,
    nowSeconds: context.nowSeconds,
  });
  context.logger.info('auth.apple.accepted', { user_id: user.id });

  return issueSession(context, user, deviceLabel);
}

export async function handleRefresh(
  request: Request,
  context: RequestContext,
): Promise<Response> {
  const body = await readJson<RefreshBody>(request, MAX_AUTH_BODY_BYTES);
  const token = readString(body.refresh_token, 'refresh_token', 512);

  const consumed = await context.repository.users.consumeRefreshToken(
    await refreshTokenHash(token),
    context.nowSeconds,
  );
  if (consumed === null) {
    throw new ApiError('unauthorized', 'Refresh token is not valid');
  }

  const user = await context.repository.users.findUserById(consumed.userId);
  if (user === null || user.disabledAt !== null) {
    throw new ApiError('unauthorized', 'Refresh token is not valid');
  }

  // Refresh tokens rotate: the presented one was consumed above, so a stolen
  // copy becomes useless the moment the legitimate device refreshes.
  return issueSession(context, user, null);
}

export async function handleSignOut(context: AuthenticatedContext): Promise<Response> {
  await context.repository.users.revokeSession(context.session.sessionId, context.nowSeconds);
  await context.repository.audit.recordAudit({
    userId: context.session.userId,
    actor: 'user',
    action: 'auth.sign_out',
    outcome: 'allowed',
    detail: null,
    correlationId: context.correlationId,
    nowSeconds: context.nowSeconds,
  });
  return jsonResponse({ signed_out: true }, { correlationId: context.correlationId });
}

/**
 * Return URL for Sign in with Apple's web flow, used by the direct-download
 * Mac app (native Sign in with Apple is unavailable to Developer ID builds).
 *
 * Apple form-posts the identity token here. This route only relays it to the
 * app's ASWebAuthenticationSession through the app's private callback scheme;
 * it creates no session and stores nothing. The app checks `state`, then
 * exchanges the token at POST /v1/auth/apple, which verifies the signature,
 * the Services ID audience and the nonce that only the app knows.
 */
export const APPLE_WEB_CALLBACK_URL = 'justspeaktoit-auth://apple-callback';
const STATE_PATTERN = /^[A-Za-z0-9_-]{16,128}$/;
const JWT_PATTERN = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/;

function relay(parameters: Record<string, string>): Response {
  const location = `${APPLE_WEB_CALLBACK_URL}?${new URLSearchParams(parameters).toString()}`;
  return new Response(null, {
    status: 303,
    headers: {
      location,
      'cache-control': 'no-store',
      'referrer-policy': 'no-referrer',
    },
  });
}

export async function handleAppleWebCallback(request: Request): Promise<Response> {
  const declared = Number(request.headers.get('content-length') ?? '0');
  const contentType = request.headers.get('content-type') ?? '';
  if (declared > MAX_AUTH_BODY_BYTES || !contentType.startsWith('application/x-www-form-urlencoded')) {
    throw new ApiError('bad_request', 'Unsupported callback');
  }
  const body = await request.arrayBuffer();
  if (body.byteLength > MAX_AUTH_BODY_BYTES) {
    throw new ApiError('bad_request', 'Unsupported callback');
  }
  const form = new URLSearchParams(new TextDecoder().decode(body));
  const state = form.get('state') ?? '';
  if (!STATE_PATTERN.test(state)) {
    throw new ApiError('bad_request', 'Missing or malformed state');
  }
  const error = form.get('error');
  if (error !== null) {
    return relay({ state, error: error === 'user_cancelled_authorize' ? 'cancelled' : 'failed' });
  }
  const identityToken = form.get('id_token') ?? '';
  if (identityToken.length > 8_192 || !JWT_PATTERN.test(identityToken)) {
    return relay({ state, error: 'failed' });
  }
  return relay({ state, id_token: identityToken });
}
