import { SignJWT, generateKeyPair } from 'jose';
import { describe, expect, it } from 'vitest';
import { APPLE_ISSUER, AppleIdentityError, verifyAppleIdentityToken } from '../src/auth/apple-identity.js';
import { sha256Hex } from '../src/crypto.js';

const AUDIENCE = 'com.justspeaktoit.test';
const RAW_NONCE = 'raw-nonce-0123456789abcdef';

async function signedToken(nonce: string) {
  const { publicKey, privateKey } = await generateKeyPair('RS256');
  const token = await new SignJWT({ nonce })
    .setProtectedHeader({ alg: 'RS256', kid: 'test' })
    .setIssuer(APPLE_ISSUER)
    .setAudience(AUDIENCE)
    .setSubject('apple-user')
    .setIssuedAt()
    .setExpirationTime('5m')
    .sign(privateKey);
  return { token, publicKey };
}

describe('verifyAppleIdentityToken nonce binding', () => {
  it('accepts a token whose nonce claim is the digest of the raw nonce', async () => {
    const { token, publicKey } = await signedToken(await sha256Hex(RAW_NONCE));
    const claims = await verifyAppleIdentityToken(token, RAW_NONCE, {
      audiences: [AUDIENCE],
      keyResolver: publicKey,
    });
    expect(claims.subject).toBe('apple-user');
  });

  it('rejects a request that submits the nonce claim itself as the raw nonce', async () => {
    const claim = await sha256Hex(RAW_NONCE);
    const { token, publicKey } = await signedToken(claim);
    await expect(
      verifyAppleIdentityToken(token, claim, { audiences: [AUDIENCE], keyResolver: publicKey }),
    ).rejects.toBeInstanceOf(AppleIdentityError);
  });

  it('rejects a token whose nonce claim is the unhashed raw nonce', async () => {
    const { token, publicKey } = await signedToken(RAW_NONCE);
    await expect(
      verifyAppleIdentityToken(token, RAW_NONCE, { audiences: [AUDIENCE], keyResolver: publicKey }),
    ).rejects.toBeInstanceOf(AppleIdentityError);
  });
});
