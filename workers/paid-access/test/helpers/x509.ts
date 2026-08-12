/**
 * A minimal X.509 certificate builder for tests.
 *
 * The chain verifier in `src/auth/apple-jws.ts` is security-critical, so it is
 * tested against certificates that are actually generated and actually signed
 * rather than against fixtures or mocks. Building a genuine three-level chain
 * here means a verifier that silently accepted everything — or silently
 * rejected everything — would fail these tests.
 */

function encodeLength(length: number): Uint8Array {
  if (length < 0x80) return new Uint8Array([length]);
  const bytes: number[] = [];
  let remaining = length;
  while (remaining > 0) {
    bytes.unshift(remaining & 0xff);
    remaining >>= 8;
  }
  return new Uint8Array([0x80 | bytes.length, ...bytes]);
}

function tagged(tag: number, content: Uint8Array): Uint8Array {
  const length = encodeLength(content.length);
  const output = new Uint8Array(1 + length.length + content.length);
  output[0] = tag;
  output.set(length, 1);
  output.set(content, 1 + length.length);
  return output;
}

function concat(parts: Uint8Array[]): Uint8Array {
  const total = parts.reduce((sum, part) => sum + part.length, 0);
  const output = new Uint8Array(total);
  let offset = 0;
  for (const part of parts) {
    output.set(part, offset);
    offset += part.length;
  }
  return output;
}

function sequence(...parts: Uint8Array[]): Uint8Array {
  return tagged(0x30, concat(parts));
}

function derSet(...parts: Uint8Array[]): Uint8Array {
  return tagged(0x31, concat(parts));
}

function integer(value: Uint8Array): Uint8Array {
  const needsPad = value[0] !== undefined && value[0] >= 0x80;
  return tagged(0x02, needsPad ? concat([new Uint8Array([0]), value]) : value);
}

function smallInteger(value: number): Uint8Array {
  return tagged(0x02, new Uint8Array([value]));
}

function bitString(content: Uint8Array): Uint8Array {
  return tagged(0x03, concat([new Uint8Array([0x00]), content]));
}

function objectIdentifier(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let index = 0; index < bytes.length; index += 1) {
    bytes[index] = Number.parseInt(hex.slice(index * 2, index * 2 + 2), 16);
  }
  return tagged(0x06, bytes);
}

function utf8String(value: string): Uint8Array {
  return tagged(0x0c, new TextEncoder().encode(value));
}

function utcTime(date: Date): Uint8Array {
  const pad = (value: number): string => `${value}`.padStart(2, '0');
  const text =
    `${pad(date.getUTCFullYear() % 100)}${pad(date.getUTCMonth() + 1)}${pad(date.getUTCDate())}` +
    `${pad(date.getUTCHours())}${pad(date.getUTCMinutes())}${pad(date.getUTCSeconds())}Z`;
  return tagged(0x17, new TextEncoder().encode(text));
}

const OID_ECDSA_SHA256 = '2a8648ce3d040302';
const OID_ECDSA_SHA384 = '2a8648ce3d040303';
const OID_COMMON_NAME = '550403';

function commonName(value: string): Uint8Array {
  return sequence(derSet(sequence(objectIdentifier(OID_COMMON_NAME), utf8String(value))));
}

/** Converts WebCrypto's raw r||s ECDSA signature into the DER form X.509 uses. */
function rawSignatureToDer(raw: Uint8Array): Uint8Array {
  const half = raw.length / 2;
  const trim = (value: Uint8Array): Uint8Array => {
    let start = 0;
    while (start < value.length - 1 && value[start] === 0) start += 1;
    return value.slice(start);
  };
  return sequence(integer(trim(raw.slice(0, half))), integer(trim(raw.slice(half))));
}

export interface TestKeyPair {
  readonly publicKey: CryptoKey;
  readonly privateKey: CryptoKey;
  readonly curve: 'P-256' | 'P-384';
}

export async function generateKeyPair(curve: 'P-256' | 'P-384'): Promise<TestKeyPair> {
  const pair = (await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: curve }, true, [
    'sign',
    'verify',
  ])) as CryptoKeyPair;
  return { publicKey: pair.publicKey, privateKey: pair.privateKey, curve };
}

export interface CertificateOptions {
  readonly subject: string;
  readonly issuer: string;
  readonly subjectKey: TestKeyPair;
  readonly issuerKey: TestKeyPair;
  readonly notBefore: Date;
  readonly notAfter: Date;
  readonly serial?: number;
}

export async function buildCertificate(options: CertificateOptions): Promise<Uint8Array> {
  const spki = new Uint8Array(
    (await crypto.subtle.exportKey('spki', options.subjectKey.publicKey)) as ArrayBuffer,
  );
  const signatureOid = options.issuerKey.curve === 'P-384' ? OID_ECDSA_SHA384 : OID_ECDSA_SHA256;
  const hash = options.issuerKey.curve === 'P-384' ? 'SHA-384' : 'SHA-256';
  const algorithm = sequence(objectIdentifier(signatureOid));

  const tbs = sequence(
    tagged(0xa0, smallInteger(2)),
    smallInteger(options.serial ?? 1),
    algorithm,
    commonName(options.issuer),
    sequence(utcTime(options.notBefore), utcTime(options.notAfter)),
    commonName(options.subject),
    spki,
  );

  const raw = new Uint8Array(
    await crypto.subtle.sign(
      { name: 'ECDSA', hash },
      options.issuerKey.privateKey,
      tbs,
    ),
  );

  return sequence(tbs, algorithm, bitString(rawSignatureToDer(raw)));
}

function toBase64(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function toBase64Url(bytes: Uint8Array): string {
  return toBase64(bytes).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

export interface TestChain {
  readonly rootDer: Uint8Array;
  readonly chainBase64: string[];
  readonly leafKey: TestKeyPair;
}

/** Builds a root → intermediate → leaf chain shaped like Apple's. */
export async function buildTestChain(options?: {
  leafNotBefore?: Date;
  leafNotAfter?: Date;
}): Promise<TestChain> {
  const now = Date.now();
  const rootKey = await generateKeyPair('P-384');
  const intermediateKey = await generateKeyPair('P-256');
  const leafKey = await generateKeyPair('P-256');

  const notBefore = new Date(now - 86_400_000);
  const notAfter = new Date(now + 86_400_000);

  const rootDer = await buildCertificate({
    subject: 'Test Root CA',
    issuer: 'Test Root CA',
    subjectKey: rootKey,
    issuerKey: rootKey,
    notBefore,
    notAfter,
    serial: 1,
  });
  const intermediateDer = await buildCertificate({
    subject: 'Test Intermediate CA',
    issuer: 'Test Root CA',
    subjectKey: intermediateKey,
    issuerKey: rootKey,
    notBefore,
    notAfter,
    serial: 2,
  });
  const leafDer = await buildCertificate({
    subject: 'Test Leaf',
    issuer: 'Test Intermediate CA',
    subjectKey: leafKey,
    issuerKey: intermediateKey,
    notBefore: options?.leafNotBefore ?? notBefore,
    notAfter: options?.leafNotAfter ?? notAfter,
    serial: 3,
  });

  return {
    rootDer,
    chainBase64: [toBase64(leafDer), toBase64(intermediateDer), toBase64(rootDer)],
    leafKey,
  };
}

/** Signs a compact JWS with the leaf key and the given `x5c` chain. */
export async function signJws(
  payload: unknown,
  chain: TestChain,
  headerOverrides: Record<string, unknown> = {},
): Promise<string> {
  const header = toBase64Url(
    new TextEncoder().encode(
      JSON.stringify({ alg: 'ES256', x5c: chain.chainBase64, ...headerOverrides }),
    ),
  );
  const body = toBase64Url(new TextEncoder().encode(JSON.stringify(payload)));
  const signature = new Uint8Array(
    await crypto.subtle.sign(
      { name: 'ECDSA', hash: 'SHA-256' },
      chain.leafKey.privateKey,
      new TextEncoder().encode(`${header}.${body}`),
    ),
  );
  return `${header}.${body}.${toBase64Url(signature)}`;
}
