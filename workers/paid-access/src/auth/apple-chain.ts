/**
 * Trust decision for an Apple `x5c` certificate chain: every certificate is
 * inside its validity window, the root is Apple Root CA G3 by exact DER, each
 * link is name-chained, CA-issued and signature-verified, and the leaf and
 * intermediate carry Apple's receipt-signing and WWDR marker OIDs.
 */

import {
  OID_APPLE_RECEIPT_SIGNING, OID_APPLE_WWDR, parseCertificate, sameBytes, verifyCertificateSignature,
  type ParsedCertificate,
} from './certificate.js';
import { base64ToBytes } from '../crypto.js';
import { CertificateError } from './der.js';

/** Leaf, intermediate and root; Apple never sends more than this. */
export const MAX_CHAIN_LENGTH = 5;

/**
 * Parses and verifies a JWS `x5c` header (leaf-first base64 DER certificates)
 * and returns the trusted leaf.
 *
 * @param rootDer DER bytes of the pinned Apple Root CA G3 certificate.
 * @param nowMs   Injected clock, so validity-window behaviour is testable.
 */
export async function verifyAppleCertificateChain(
  x5c: readonly string[],
  rootDer: Uint8Array,
  nowMs: number,
): Promise<ParsedCertificate> {
  if (x5c.length < 2) {
    throw new CertificateError('Signed payload is missing an x5c certificate chain');
  }
  if (x5c.length > MAX_CHAIN_LENGTH) {
    throw new CertificateError('Certificate chain is longer than permitted');
  }

  const chain = x5c.map((entry) => parseCertificate(base64ToBytes(entry)));

  for (const certificate of chain) {
    if (nowMs < certificate.notBeforeMs || nowMs > certificate.notAfterMs) {
      throw new CertificateError('Certificate in chain is outside its validity window');
    }
  }

  const root = chain[chain.length - 1] as ParsedCertificate;
  if (!sameBytes(root.der, rootDer)) {
    throw new CertificateError('Certificate chain does not terminate at the pinned Apple root');
  }

  for (let index = 0; index < chain.length - 1; index += 1) {
    const child = chain[index] as ParsedCertificate;
    const issuer = chain[index + 1] as ParsedCertificate;

    // Names must chain. Without this a valid signature from an unrelated Apple
    // certificate would be accepted as if it had issued this one.
    if (!sameBytes(child.issuerDer, issuer.subjectDer)) {
      throw new CertificateError('Certificate issuer does not match the next certificate subject');
    }
    if (!issuer.isCertificateAuthority) {
      throw new CertificateError('Certificate chain contains a non-CA issuer');
    }
    if (!(await verifyCertificateSignature(child, issuer))) {
      throw new CertificateError('Certificate chain signature verification failed');
    }
  }

  const leaf = chain[0] as ParsedCertificate;

  // Apple requires the marker OIDs that identify these certificates as issued
  // for App Store receipt signing. Checking them stops any other certificate
  // that legitimately chains to the Apple root from signing our payloads.
  if (!leaf.extensionOids.has(OID_APPLE_RECEIPT_SIGNING)) {
    throw new CertificateError('Leaf certificate is not an App Store receipt-signing certificate');
  }
  const intermediate = chain[1] as ParsedCertificate;
  if (!intermediate.extensionOids.has(OID_APPLE_WWDR)) {
    throw new CertificateError('Intermediate certificate is not an Apple WWDR certificate');
  }
  return leaf;
}
