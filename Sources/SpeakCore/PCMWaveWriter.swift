import Foundation

/// Wraps raw little-endian PCM samples in a canonical 44-byte RIFF/WAVE header.
///
/// Several speech-generation APIs return headerless PCM (Gemini returns
/// `audio/L16;codec=pcm;rate=24000`). `AVAudioPlayer` cannot open those bytes,
/// so the header is added on the client before the file is written.
public enum PCMWaveWriter {
    /// Standard PCM header: no extension chunk, integer samples.
    private static let pcmFormatTag: UInt16 = 1
    private static let headerByteCount = 44

    /// - Parameters:
    ///   - pcm: Raw interleaved sample bytes, little-endian.
    ///   - sampleRate: Frames per second, for example `24_000`.
    ///   - channels: Interleaved channel count.
    ///   - bitsPerSample: Bit depth of one sample, for example `16`.
    public static func wavData(
        pcm: Data,
        sampleRate: Int,
        channels: Int = 1,
        bitsPerSample: Int = 16
    ) -> Data {
        let bytesPerSample = max(bitsPerSample / 8, 1)
        let blockAlign = channels * bytesPerSample
        let byteRate = sampleRate * blockAlign

        var data = Data(capacity: headerByteCount + pcm.count)
        func appendASCII(_ value: String) { data.append(Data(value.utf8)) }
        func appendUInt16(_ value: UInt16) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        func appendUInt32(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }

        appendASCII("RIFF")
        appendUInt32(UInt32(headerByteCount - 8 + pcm.count))
        appendASCII("WAVE")
        appendASCII("fmt ")
        appendUInt32(16)
        appendUInt16(pcmFormatTag)
        appendUInt16(UInt16(channels))
        appendUInt32(UInt32(sampleRate))
        appendUInt32(UInt32(byteRate))
        appendUInt16(UInt16(blockAlign))
        appendUInt16(UInt16(bitsPerSample))
        appendASCII("data")
        appendUInt32(UInt32(pcm.count))
        data.append(pcm)
        return data
    }
}
