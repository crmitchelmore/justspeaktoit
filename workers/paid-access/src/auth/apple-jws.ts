/**
 * Minimal DER / X.509 reader and JWS `x5c` chain verifier.
 *
 * Apple's StoreKit signed transactions and App Store Server Notifications are
 * JWS blobs whose trust comes entirely from the `x5c` certificate chain in the
 * protected header. Decoding the payload proves nothing, so this module does
 * the real work: it parses each certificate, verifies every link in the chain
 * with WebCrypto, pins the root to Apple Root CA G3 by exact DER comparison,
 * checks validity windows, and only then verifies the JWS signature with the
 * leaf key.
 *
 * Deliberately narrow: it supports exactly the ECDSA profile Apple uses
 * (P-256/SHA-256 leaf and intermediate, P-384/SHA-384 root) and rejects
 * anything else rather than trying to be a general X.509 implementation.
 */

import { base64ToBytes, base64UrlToBytes } from '../crypto.js';

export class CertificateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CertificateError';
  }
}

interface DerNode {
  readonly tag: number;
  readonly contentStart: number;
  readonly contentEnd: number;
  readonly end: number;
  readonly start: number;
}

const MAX_CHAIN_LENGTH = 5;

function readNode(bytes: Uint8Array, offset: number): DerNode {
  if (offset + 2 > bytes.length) {
    throw new CertificateError('Truncated DER node');
  }
  const tag = bytes[offset] as number;
  const first = bytes[offset + 1] as number;
  let length: number;
  let contentStart: number;

  if (first < 0x80) {
    length = first;
    contentStart = offset + 2;
  } else {
    const lengthBytes = first & 0x7f;
    if (lengthBytes === 0 || lengthBytes > 4) {
      throw new CertificateError('Unsupported DER length encoding');
    }
    if (offset + 2 + lengthBytes > bytes.length) {
      throw new CertificateError('Truncated DER length');
    }
    length = 0;
    for (let index = 0; index < lengthBytes; index += 1) {
      length = length * 256 + (bytes[offset + 2 + index] as number);
    }
    contentStart = offset + 2 + lengthBytes;
  }

  const contentEnd = contentStart + length;
  if (contentEnd > bytes.length) {
    throw new CertificateError('DER node exceeds buffer');
  }
  return { tag, start: offset, contentStart, contentEnd, end: contentEnd };
}

function childNodes(bytes: Uint8Array, node: DerNode): DerNode[] {
  const nodes: DerNode[] = [];
  let offset = node.contentStart;
  while (offset < node.contentEnd) {
    const child = readNode(bytes, offset);
    nodes.push(child);
    offset = child.end;
  }
  return nodes;
}

function nodeBytes(bytes: Uint8Array, node: DerNode): Uint8Array {
  return bytes.slice(node.start, node.end);
}

function oidHex(bytes: Uint8Array, node: DerNode): string {
  if (node.tag !== 0x06) {
    throw new CertificateError('Expected OBJECT IDENTIFIER');
  }
  return Array.from(bytes.slice(node.contentStart, node.contentEnd))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

const OID_ECDSA_SHA256 = '2a8648ce3d040302';
const OID_ECDSA_SHA384 = '2a8648ce3d040303';
const OID_EC_PUBLIC_KEY = '2a8648ce3d0201';
const OID_P256 = '2a8648ce3d030107';
const OID_P384 = '2b81040022';

interface SignatureProfile {
  readonly hash: 'SHA-256' | 'SHA-384';
  readonly componentLength: number;
}

function signatureProfile(oid: string): SignatureProfile {
  if (oid === OID_ECDSA_SHA256) return { hash: 'SHA-256', componentLength: 32 };
  if (oid === OID_ECDSA_SHA384) return { hash: 'SHA-384', componentLength: 48 };
  throw new CertificateError(`Unsupported certificate signature algorithm: ${oid}`);
}

function parseAsn1Time(bytes: Uint8Array, node: DerNode): number {
  const text = new TextDecoder().decode(bytes.slice(node.contentStart, node.contentEnd));
  if (node.tag === 0x17) {
    // UTCTime: YYMMDDHHMMSSZ — years 50-99 map to 19xx, 00-49 to 20xx.
    const match = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text);
    if (!match) throw new CertificateError('Malformed UTCTime');
    const twoDigitYear = Number(match[1]);
    const year = twoDigitYear >= 50 ? 1900 + twoDigitYear : 2000 + twoDigitYear;
    return Date.UTC(
      year,
      Number(match[2]) - 1,
      Number(match[3]),
      Number(match[4]),
      Number(match[5]),
      Number(match[6]),
    );
  }
  if (node.tag === 0x18) {
    const match = /^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})Z$/.exec(text);
    if (!match) throw new CertificateError('Malformed GeneralizedTime');
    return Date.UTC(
      Number(match[1]),
      Number(match[2]) - 1,
      Number(match[3]),
      Number(match[4]),
      Number(match[5]),
      Number(match[6]),
    );
  }
  throw new CertificateError('Unsupported ASN.1 time type');
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

  return {
    der,
    tbs: nodeBytes(der, tbsNode),
    signature,
    signatureOid,
    spki: nodeBytes(der, spkiNode),
    namedCurve,
    notBeforeMs: parseAsn1Time(der, notBeforeNode),
    notAfterMs: parseAsn1Time(der, notAfterNode),
  };
}

/** Converts a DER `SEQUENCE { r INTEGER, s INTEGER }` into WebCrypto's raw r||s form. */
function derSignatureToRaw(signature: Uint8Array, componentLength: number): Uint8Array {
  const sequence = readNode(signature, 0);
  if (sequence.tag !== 0x30) {
    throw new CertificateError('ECDSA signature is not a SEQUENCE');
  }
  const [rNode, sNode] = childNodes(signature, sequence);
  if (!rNode || !sNode) {
    throw new CertificateError('ECDSA signature is missing r or s');
  }
  const output = new Uint8Array(componentLength * 2);
  const components = [rNode, sNode];
  for (let index = 0; index < components.length; index += 1) {
    const node = components[index] as DerNode;
    let value = signature.slice(node.contentStart, node.contentEnd);
    // DER integers are signed, so strip any leading zero padding byte.
    while (value.length > componentLength && value[0] === 0x00) {
      value = value.slice(1);
    }
    if (value.length > componentLength) {
      throw new CertificateError('ECDSA signature component is too large');
    }
    output.set(value, index * componentLength + (componentLength - value.length));
  }
  return output;
}

async function verifyCertificateSignature(
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

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.length !== right.length) return false;
  let mismatch = 0;
  for (let index = 0; index < left.length; index += 1) {
    mismatch |= (left[index] as number) ^ (right[index] as number);
  }
  return mismatch === 0;
}

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
  if (!Array.isArray(chainBase64) || chainBase64.length < 2) {
    throw new CertificateError('Signed payload is missing an x5c certificate chain');
  }
  if (chainBase64.length > MAX_CHAIN_LENGTH) {
    throw new CertificateError('Certificate chain is longer than permitted');
  }

  const chain = chainBase64.map((entry) => parseCertificate(base64ToBytes(entry)));

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
    if (!(await verifyCertificateSignature(child, issuer))) {
      throw new CertificateError('Certificate chain signature verification failed');
    }
  }

  const leaf = chain[0] as ParsedCertificate;
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
