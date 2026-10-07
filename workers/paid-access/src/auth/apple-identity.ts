/**
 * Sign in with Apple identity-token verification.
 *
 * The token is verified, never merely decoded: the signature is checked against
 * Apple's published JWKS by key id, and issuer, audience, algorithm, expiry and
 * nonce are all asserted. A client that supplies a syntactically valid but
 * unverifiable token gets a 401 and no user record is created.
 */

import { createRemoteJWKSet, jwtVerify, type JWTPayload } from 'jose';
import { sha256Hex, timingSafeEqual } from '../crypto.js';

export const APPLE_ISSUER = 'https://appleid.apple.com';
const APPLE_JWKS_URL = new URL('https://appleid.apple.com/auth/keys');

export class AppleIdentityError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'AppleIdentityError';
  }
}

export interface AppleIdentityClaims {
  readonly subject: string;
  readonly email: string | null;
  readonly emailVerified: boolean;
  readonly audience: string;
}

export interface AppleIdentityVerifierOptions {
  readonly audiences: readonly string[];
  /** Injectable for tests; production uses Apple's remote JWKS with jose's cache. */
  readonly keyResolver?: Parameters<typeof jwtVerify>[1];
  readonly clockToleranceSeconds?: number;
}

let cachedRemoteJwks: ReturnType<typeof createRemoteJWKSet> | undefined;

function remoteJwks(): ReturnType<typeof createRemoteJWKSet> {
  cachedRemoteJwks ??= createRemoteJWKSet(APPLE_JWKS_URL, {
    cooldownDuration: 30_000,
    cacheMaxAge: 600_000,
    timeoutDuration: 5_000,
  });
  return cachedRemoteJwks;
}

/**
 * Apple echoes the `nonce` exactly as the client set it. Native clients set it
 * to the SHA-256 hex digest of a locally generated random value, so we accept
 * either the raw value or its digest and compare in constant time.
 */
async function nonceMatches(expectedRawNonce: string, tokenNonce: string): Promise<boolean> {
  if (timingSafeEqual(expectedRawNonce, tokenNonce)) return true;
  const digest = await sha256Hex(expectedRawNonce);
  return timingSafeEqual(digest, tokenNonce);
}

export async function verifyAppleIdentityToken(
  identityToken: string,
  rawNonce: string,
  options: AppleIdentityVerifierOptions,
): Promise<AppleIdentityClaims> {
  if (identityToken.split('.').length !== 3) {
    throw new AppleIdentityError('Identity token is not a compact JWS');
  }
  if (rawNonce.length < 16 || rawNonce.length > 256) {
    throw new AppleIdentityError('A nonce between 16 and 256 characters is required');
  }

  let payload: JWTPayload;
  try {
    const result = await jwtVerify(identityToken, options.keyResolver ?? remoteJwks(), {
      issuer: APPLE_ISSUER,
      audience: [...options.audiences],
      algorithms: ['RS256'],
      clockTolerance: options.clockToleranceSeconds ?? 30,
      requiredClaims: ['sub', 'aud', 'iss', 'exp', 'iat'],
    });
    payload = result.payload;
  } catch (error) {
    throw new AppleIdentityError(
      `Identity token verification failed: ${error instanceof Error ? error.name : 'unknown'}`,
    );
  }

  const subject = payload.sub;
  if (typeof subject !== 'string' || subject.length === 0) {
    throw new AppleIdentityError('Identity token has no subject');
  }

  const tokenNonce = payload['nonce'];
  if (typeof tokenNonce !== 'string' || tokenNonce.length === 0) {
    throw new AppleIdentityError('Identity token is missing the nonce claim');
  }
  if (!(await nonceMatches(rawNonce, tokenNonce))) {
    throw new AppleIdentityError('Identity token nonce does not match the request');
  }

  const audience = Array.isArray(payload.aud) ? payload.aud[0] : payload.aud;
  if (typeof audience !== 'string') {
    throw new AppleIdentityError('Identity token has no usable audience');
  }

  const emailClaim = payload['email'];
  const emailVerifiedClaim = payload['email_verified'];

  return {
    subject,
    email: typeof emailClaim === 'string' ? emailClaim : null,
    // Apple sends this as a boolean or the string "true" depending on flow.
    emailVerified: emailVerifiedClaim === true || emailVerifiedClaim === 'true',
    audience,
  };
}
