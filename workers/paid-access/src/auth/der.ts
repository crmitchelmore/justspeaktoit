/**
 * Minimal DER reader: just enough ASN.1 to walk the X.509 certificates and
 * ECDSA signatures Apple signs with. Every malformed input throws
 * `CertificateError` instead of reading past a node.
 */

export class CertificateError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'CertificateError';
  }
}

export interface DerNode {
  readonly tag: number;
  readonly contentStart: number;
  readonly contentEnd: number;
  readonly end: number;
  readonly start: number;
}

export function readNode(bytes: Uint8Array, offset: number): DerNode {
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

export function childNodes(bytes: Uint8Array, node: DerNode): DerNode[] {
  const nodes: DerNode[] = [];
  let offset = node.contentStart;
  while (offset < node.contentEnd) {
    const child = readNode(bytes, offset);
    nodes.push(child);
    offset = child.end;
  }
  return nodes;
}

export function nodeBytes(bytes: Uint8Array, node: DerNode): Uint8Array {
  return bytes.slice(node.start, node.end);
}

export function oidHex(bytes: Uint8Array, node: DerNode): string {
  if (node.tag !== 0x06) {
    throw new CertificateError('Expected OBJECT IDENTIFIER');
  }
  return Array.from(bytes.slice(node.contentStart, node.contentEnd))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

export function parseAsn1Time(bytes: Uint8Array, node: DerNode): number {
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

/** Converts a DER `SEQUENCE { r INTEGER, s INTEGER }` into WebCrypto's raw r||s form. */
export function derSignatureToRaw(signature: Uint8Array, componentLength: number): Uint8Array {
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
