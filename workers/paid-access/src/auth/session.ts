/**
 * Session tokens.
 *
 * Access tokens are short-lived HS256 JWTs signed with a Worker secret; refresh
 * tokens are opaque random strings stored only as SHA-256 hashes. Verification
 * asserts algorithm, issuer, audience and expiry — a decoded-but-unverified
 * token is never accepted anywhere in this codebase.
 */

import { SignJWT, jwtVerify } from 'jose';
import { randomToken, sha256Hex } from '../crypto.js';

export const SESSION_ISSUER = 'https://justspeaktoit.com/paid-access';
export const SESSION_AUDIENCE = 'justspeaktoit-app';

export type UserRole = 'user' | 'support' | 'admin';

export interface SessionClaims {
  readonly userId: string;
  readonly sessionId: string;
  readonly role: UserRole;
  readonly expiresAt: number;
}

export class SessionError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SessionError';
  }
}

function signingKey(secret: string): Uint8Array {
  if (secret.length < 32) {
    throw new SessionError('Session signing key must be at least 32 characters');
  }
  return new TextEncoder().encode(secret);
}

export async function issueAccessToken(
  secret: string,
  claims: { userId: string; sessionId: string; role: UserRole },
  ttlSeconds: number,
  nowSeconds: number,
): Promise<{ token: string; expiresAt: number }> {
  const expiresAt = nowSeconds + ttlSeconds;
  const token = await new SignJWT({ sid: claims.sessionId, role: claims.role })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setIssuer(SESSION_ISSUER)
    .setAudience(SESSION_AUDIENCE)
    .setSubject(claims.userId)
    .setIssuedAt(nowSeconds)
    .setExpirationTime(expiresAt)
    .setJti(crypto.randomUUID())
    .sign(signingKey(secret));
  return { token, expiresAt };
}

export async function verifyAccessToken(secret: string, token: string): Promise<SessionClaims> {
  let payload;
  try {
    const result = await jwtVerify(token, signingKey(secret), {
      issuer: SESSION_ISSUER,
      audience: SESSION_AUDIENCE,
      algorithms: ['HS256'],
      requiredClaims: ['sub', 'exp', 'iat', 'jti'],
    });
    payload = result.payload;
  } catch (error) {
    throw new SessionError(
      `Access token rejected: ${error instanceof Error ? error.name : 'unknown'}`,
    );
  }

  const userId = payload.sub;
  const sessionId = payload['sid'];
  const role = payload['role'];
  if (typeof userId !== 'string' || typeof sessionId !== 'string') {
    throw new SessionError('Access token is missing subject or session id');
  }
  if (role !== 'user' && role !== 'support' && role !== 'admin') {
    throw new SessionError('Access token carries an unknown role');
  }
  if (typeof payload.exp !== 'number') {
    throw new SessionError('Access token has no expiry');
  }

  return { userId, sessionId, role, expiresAt: payload.exp };
}

export interface RefreshTokenMaterial {
  readonly token: string;
  readonly hash: string;
}

export async function createRefreshToken(): Promise<RefreshTokenMaterial> {
  const token = randomToken(32);
  return { token, hash: await sha256Hex(token) };
}

export async function refreshTokenHash(token: string): Promise<string> {
  return sha256Hex(token);
}

export function bearerToken(request: Request): string | null {
  const header = request.headers.get('authorization');
  if (header === null) return null;
  const match = /^Bearer\s+([A-Za-z0-9._~+/=-]+)$/.exec(header.trim());
  return match?.[1] ?? null;
}
