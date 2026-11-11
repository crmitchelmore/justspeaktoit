import { ApiError } from '../http.js';

/**
 * The exact duration of a linear-PCM WAV payload.
 *
 * Duration is what gets billed, so it is measured from the payload's own header
 * rather than assumed from its size: a fixed bytes-per-second guess is wrong by
 * a factor of six between 16 kHz mono and 48 kHz stereo, and wrong by an order
 * of magnitude for a compressed container. Nothing we route to reports the
 * duration back, so the payload is the only source of truth — which is why the
 * accepted content types are limited to what this can read.
 */
export function wavDurationSeconds(audio: Uint8Array): number {
  const view = new DataView(audio.buffer, audio.byteOffset, audio.byteLength);
  const tag = (offset: number): string =>
    String.fromCharCode(
      view.getUint8(offset),
      view.getUint8(offset + 1),
      view.getUint8(offset + 2),
      view.getUint8(offset + 3),
    );

  if (audio.byteLength < 44 || tag(0) !== 'RIFF' || tag(8) !== 'WAVE') {
    throw new ApiError('bad_request', 'Audio body is not a WAV payload');
  }

  let framesPerSecond: number | null = null;
  let bytesPerFrame: number | null = null;
  let dataBytes: number | null = null;
  let offset = 12;
  while (offset + 8 <= audio.byteLength) {
    const chunkId = tag(offset);
    const chunkSize = view.getUint32(offset + 4, true);
    if (chunkId === 'fmt ') {
      if (framesPerSecond !== null || chunkSize < 16 || offset + 8 + chunkSize > audio.byteLength) {
        throw new ApiError('bad_request', 'Audio body has an invalid WAV format chunk');
      }
      const format = view.getUint16(offset + 8, true);
      const channels = view.getUint16(offset + 10, true);
      const sampleRate = view.getUint32(offset + 12, true);
      const byteRate = view.getUint32(offset + 16, true);
      const blockAlign = view.getUint16(offset + 20, true);
      const bitsPerSample = view.getUint16(offset + 22, true);
      const expectedBlockAlign = channels * (bitsPerSample / 8);
      // byteRate and blockAlign are redundant client-controlled fields, not
      // independent measurements. Accept integer PCM only and require every
      // field to agree before using the actual frame count for metering.
      if (format !== 1 || channels === 0 || sampleRate === 0
        || ![8, 16, 24, 32].includes(bitsPerSample)
        || blockAlign !== expectedBlockAlign || byteRate !== sampleRate * expectedBlockAlign) {
        throw new ApiError('bad_request', 'Audio body has inconsistent PCM geometry');
      }
      framesPerSecond = sampleRate;
      bytesPerFrame = blockAlign;
    } else if (chunkId === 'data') {
      // A streamed WAV can declare a zero or overlong size; trust what arrived.
      const declared = chunkSize === 0 ? Number.MAX_SAFE_INTEGER : chunkSize;
      dataBytes = Math.min(declared, audio.byteLength - (offset + 8));
      break;
    }
    // Chunks are word-aligned, so an odd size is followed by a pad byte.
    offset += 8 + chunkSize + (chunkSize % 2);
  }

  if (framesPerSecond === null || bytesPerFrame === null
    || dataBytes === null || dataBytes <= 0 || dataBytes % bytesPerFrame !== 0) {
    throw new ApiError('bad_request', 'Audio body is not a readable WAV payload');
  }
  return (dataBytes / bytesPerFrame) / framesPerSecond;
}
