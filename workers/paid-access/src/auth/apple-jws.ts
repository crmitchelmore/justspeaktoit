/**
 * Apple-signed compact JWS verification.
 *
 * Apple's StoreKit signed transactions and App Store Server Notifications are
 * JWS blobs whose trust comes entirely from the `x5c` certificate chain in the
 * protected header. Decoding the payload proves nothing, so this module parses
 * the compact JWS, has `verifyAppleCertificateChain` (apple-chain.ts) establish
 * the chain against the pinned Apple Root CA G3, and only then verifies the JWS
 * signature with the leaf key. DER reading lives in der.ts and certificate
 * parsing in certificate.ts.
 *
 * Out of scope, and accepted knowingly: OCSP and CRL revocation checking. This
 * is a deliberate security and availability trade-off, not a proof of safety.
 * A compromised intermediate is genuinely accepted here: its key can sign a
 * forged leaf carrying the receipt-signing extension, and that chain still
 * links back to the pinned root, so Apple's own root key is not required to
 * produce a payload we accept. What buys the trade-off is that revocation
 * checking would put a third-party network call on the hot path of every
 * purchase verification, and Apple publishes intermediate compromises through
 * channels we would act on well inside these certificates' validity windows.
 */

import { verifyAppleCertificateChain } from './apple-chain.js';
import { base64UrlToBytes } from '../crypto.js';
import { CertificateError } from './der.js';

export { CertificateError } from './der.js';
export { parseCertificate, type ParsedCertificate } from './certificate.js';

export interface AppleJwsHeader {
  readonly alg: string;
  readonly x5c?: string[];
}

/**
 * Verifies an Apple-signed JWS and returns its payload.
 *
 * @param compactJws  The `header.payload.signature` string.
 * @param rootDer     DER bytes of the pinned Apple Root CA G3 certificate.
 * @param nowMs       Injected clock, so validity-window behaviour is testable.
 */
export async function verifyAppleSignedJws<T>(
  compactJws: string,
  rootDer: Uint8Array,
  nowMs: number,
): Promise<T> {
  const segments = compactJws.split('.');
  if (segments.length !== 3) {
    throw new CertificateError('Signed payload is not a compact JWS');
  }
  const [headerSegment, payloadSegment, signatureSegment] = segments as [string, string, string];

  let header: AppleJwsHeader;
  try {
    header = JSON.parse(
      new TextDecoder().decode(base64UrlToBytes(headerSegment)),
    ) as AppleJwsHeader;
  } catch {
    throw new CertificateError('Signed payload header is not valid JSON');
  }

  if (header.alg !== 'ES256') {
    throw new CertificateError(`Unexpected JWS algorithm: ${String(header.alg)}`);
  }
  const chainBase64 = header.x5c;
  if (!Array.isArray(chainBase64)) {
    throw new CertificateError('Signed payload is missing an x5c certificate chain');
  }
  const leaf = await verifyAppleCertificateChain(chainBase64, rootDer, nowMs);

  if (leaf.namedCurve !== 'P-256') {
    throw new CertificateError('Leaf certificate does not use P-256');
  }
  const leafKey = await crypto.subtle.importKey(
    'spki',
    leaf.spki,
    { name: 'ECDSA', namedCurve: 'P-256' },
    false,
    ['verify'],
  );
  const signingInput = new TextEncoder().encode(`${headerSegment}.${payloadSegment}`);
  const signature = base64UrlToBytes(signatureSegment);
  const verified = await crypto.subtle.verify(
    { name: 'ECDSA', hash: 'SHA-256' },
    leafKey,
    signature,
    signingInput,
  );
  if (!verified) {
    throw new CertificateError('Signed payload signature is invalid');
  }

  try {
    return JSON.parse(new TextDecoder().decode(base64UrlToBytes(payloadSegment))) as T;
  } catch {
    throw new CertificateError('Signed payload body is not valid JSON');
  }
}
