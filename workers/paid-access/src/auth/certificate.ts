/**
 * X.509 certificate parsing and signature checks for the narrow ECDSA profile
 * Apple uses (P-256/SHA-256 leaf and intermediate, P-384/SHA-384 root).
 * Anything else is rejected rather than handled as general X.509.
 */

import {
  CertificateError, childNodes, derSignatureToRaw, nodeBytes, oidHex, parseAsn1Time, readNode,
  type DerNode,
} from './der.js';

const OID_ECDSA_SHA256 = '2a8648ce3d040302';
const OID_ECDSA_SHA384 = '2a8648ce3d040303';
const OID_EC_PUBLIC_KEY = '2a8648ce3d0201';
const OID_P256 = '2a8648ce3d030107';
const OID_P384 = '2b81040022';
const OID_BASIC_CONSTRAINTS = '551d13';
/** Apple's "Mac App Store receipt signing" OID, required on the leaf. */
export const OID_APPLE_RECEIPT_SIGNING = '2a864886f76364060b01';
/** Apple's WWDR OID, required on the intermediate. */
export const OID_APPLE_WWDR = '2a864886f76364060201';

interface SignatureProfile {
  readonly hash: 'SHA-256' | 'SHA-384';
  readonly componentLength: number;
}

function signatureProfile(oid: string): SignatureProfile {
  if (oid === OID_ECDSA_SHA256) return { hash: 'SHA-256', componentLength: 32 };
  if (oid === OID_ECDSA_SHA384) return { hash: 'SHA-384', componentLength: 48 };
  throw new CertificateError(`Unsupported certificate signature algorithm: ${oid}`);
}

export interface ParsedCertificate {
  readonly der: Uint8Array;
  readonly tbs: Uint8Array;
  readonly signature: Uint8Array;
  readonly signatureOid: string;
  readonly spki: Uint8Array;
  readonly namedCurve: 'P-256' | 'P-384';
  readonly notBeforeMs: number;
  readonly notAfterMs: number;
  /** Raw DER of the issuer and subject names, compared to chain certificates. */
  readonly issuerDer: Uint8Array;
  readonly subjectDer: Uint8Array;
  /** Extension OIDs present on the certificate, hex encoded. */
  readonly extensionOids: ReadonlySet<string>;
  readonly isCertificateAuthority: boolean;
}

export function parseCertificate(der: Uint8Array): ParsedCertificate {
  const certificate = readNode(der, 0);
  if (certificate.tag !== 0x30) {
    throw new CertificateError('Certificate is not a SEQUENCE');
  }
  const [tbsNode, algorithmNode, signatureNode] = childNodes(der, certificate);
  if (!tbsNode || !algorithmNode || !signatureNode) {
    throw new CertificateError('Certificate is missing required fields');
  }

  const algorithmChildren = childNodes(der, algorithmNode);
  const algorithmOidNode = algorithmChildren[0];
  if (!algorithmOidNode) throw new CertificateError('Missing signature algorithm OID');
  const signatureOid = oidHex(der, algorithmOidNode);

  if (signatureNode.tag !== 0x03) {
    throw new CertificateError('Signature value is not a BIT STRING');
  }
  // First content byte of a BIT STRING is the unused-bit count.
  const signature = der.slice(signatureNode.contentStart + 1, signatureNode.contentEnd);

  const tbsChildren = childNodes(der, tbsNode);
  // A [0] EXPLICIT version tag shifts every subsequent field by one.
  const hasVersion = tbsChildren[0]?.tag === 0xa0;
  const validityNode = tbsChildren[hasVersion ? 4 : 3];
  const spkiNode = tbsChildren[hasVersion ? 6 : 5];
  if (!validityNode || !spkiNode) {
    throw new CertificateError('Certificate is missing validity or public key');
  }

  const [notBeforeNode, notAfterNode] = childNodes(der, validityNode);
  if (!notBeforeNode || !notAfterNode) {
    throw new CertificateError('Certificate validity is malformed');
  }

  const spkiChildren = childNodes(der, spkiNode);
  const spkiAlgorithmNode = spkiChildren[0];
  if (!spkiAlgorithmNode) throw new CertificateError('Missing SubjectPublicKeyInfo algorithm');
  const spkiAlgorithmChildren = childNodes(der, spkiAlgorithmNode);
  const keyTypeNode = spkiAlgorithmChildren[0];
  const curveNode = spkiAlgorithmChildren[1];
  if (!keyTypeNode || !curveNode) {
    throw new CertificateError('Missing public key algorithm parameters');
  }
  if (oidHex(der, keyTypeNode) !== OID_EC_PUBLIC_KEY) {
    throw new CertificateError('Certificate does not carry an EC public key');
  }
  const curveOid = oidHex(der, curveNode);
  const namedCurve = curveOid === OID_P256 ? 'P-256' : curveOid === OID_P384 ? 'P-384' : null;
  if (namedCurve === null) {
    throw new CertificateError(`Unsupported named curve: ${curveOid}`);
  }

  const issuerNode = tbsChildren[hasVersion ? 3 : 2];
  const subjectNode = tbsChildren[hasVersion ? 5 : 4];
  if (!issuerNode || !subjectNode) {
    throw new CertificateError('Certificate is missing issuer or subject');
  }

  const extensions = parseExtensions(der, tbsChildren);

  return {
    der,
    tbs: nodeBytes(der, tbsNode),
    signature,
    signatureOid,
    spki: nodeBytes(der, spkiNode),
    namedCurve,
    notBeforeMs: parseAsn1Time(der, notBeforeNode),
    notAfterMs: parseAsn1Time(der, notAfterNode),
    issuerDer: nodeBytes(der, issuerNode),
    subjectDer: nodeBytes(der, subjectNode),
    extensionOids: extensions.oids,
    isCertificateAuthority: extensions.isCertificateAuthority,
  };
}

/**
 * Reads the optional `[3] EXPLICIT Extensions` field.
 *
 * Only the two things we act on are decoded: which extension OIDs are present,
 * and whether basicConstraints marks the certificate as a CA.
 */
function parseExtensions(
  bytes: Uint8Array,
  tbsChildren: readonly DerNode[],
): { oids: ReadonlySet<string>; isCertificateAuthority: boolean } {
  const container = tbsChildren.find((child) => child.tag === 0xa3);
  const oids = new Set<string>();
  if (container === undefined) {
    return { oids, isCertificateAuthority: false };
  }

  const [sequence] = childNodes(bytes, container);
  if (!sequence || sequence.tag !== 0x30) {
    return { oids, isCertificateAuthority: false };
  }

  let isCertificateAuthority = false;
  for (const extension of childNodes(bytes, sequence)) {
    const parts = childNodes(bytes, extension);
    const oidNode = parts[0];
    if (!oidNode || oidNode.tag !== 0x06) continue;
    const oid = oidHex(bytes, oidNode);
    oids.add(oid);

    if (oid === OID_BASIC_CONSTRAINTS) {
      const valueNode = parts[parts.length - 1];
      if (valueNode === undefined || valueNode.tag !== 0x04) continue;
      const [constraints] = childNodes(bytes, valueNode);
      if (!constraints || constraints.tag !== 0x30) continue;
      const [caFlag] = childNodes(bytes, constraints);
      isCertificateAuthority =
        caFlag !== undefined && caFlag.tag === 0x01 && bytes[caFlag.contentStart] !== 0x00;
    }
  }

  return { oids, isCertificateAuthority };
}

export async function verifyCertificateSignature(
  child: ParsedCertificate,
  issuer: ParsedCertificate,
): Promise<boolean> {
  const profile = signatureProfile(child.signatureOid);
  const key = await crypto.subtle.importKey(
    'spki',
    issuer.spki,
    { name: 'ECDSA', namedCurve: issuer.namedCurve },
    false,
    ['verify'],
  );
  const raw = derSignatureToRaw(child.signature, profile.componentLength);
  return crypto.subtle.verify(
    { name: 'ECDSA', hash: profile.hash },
    key,
    raw,
    child.tbs,
  );
}

export function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let mismatch = 0;
  for (let index = 0; index < left.length; index += 1) {
    mismatch |= (left[index] as number) ^ (right[index] as number);
  }
  return mismatch === 0;
}
