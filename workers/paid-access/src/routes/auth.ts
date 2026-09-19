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

  const sessionId = await context.repository.createAuthSession({
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

  const entitlement = await context.repository.ensureEntitlement(user.id, context.nowSeconds);

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
    await context.repository.recordAudit({
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

  const user = await context.repository.upsertUserByAppleSub(
    claims.subject,
    claims.emailVerified ? claims.email : null,
    context.nowSeconds,
  );
  if (user.disabledAt !== null) {
    throw new ApiError('forbidden', 'This account is disabled');
  }

  await context.repository.recordAudit({
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

  const consumed = await context.repository.consumeRefreshToken(
    await refreshTokenHash(token),
    context.nowSeconds,
  );
  if (consumed === null) {
    throw new ApiError('unauthorized', 'Refresh token is not valid');
  }

  const user = await context.repository.findUserById(consumed.userId);
  if (user === null || user.disabledAt !== null) {
    throw new ApiError('unauthorized', 'Refresh token is not valid');
  }

  // Refresh tokens rotate: the presented one was consumed above, so a stolen
  // copy becomes useless the moment the legitimate device refreshes.
  return issueSession(context, user, null);
}

export async function handleSignOut(context: AuthenticatedContext): Promise<Response> {
  await context.repository.revokeSession(context.session.sessionId, context.nowSeconds);
  await context.repository.recordAudit({
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
