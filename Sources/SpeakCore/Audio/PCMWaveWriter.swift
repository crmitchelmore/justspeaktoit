import Foundation

/// Wraps raw little-endian PCM samples in a canonical 44-byte RIFF/WAVE header.
///
/// Several speech-generation APIs return headerless PCM (Gemini returns
/// `audio/L16;codec=pcm;rate=24000`). `AVAudioPlayer` cannot open those bytes,
/// so the header is added on the client before the file is written.
///
/// The header's fields are fixed-width, so the format a provider reports is not
/// automatically representable: a RIFF header cannot describe a negative sample
/// rate, more than `UInt16.max` channels, or a payload that overflows the 32-bit
/// chunk sizes. Provider metadata is untrusted input, so `wavData` reports an
/// unrepresentable format as `nil` rather than trapping on the conversion.
public enum PCMWaveWriter {
    /// Standard PCM header: no extension chunk, integer samples.
    private static let pcmFormatTag: UInt16 = 1
    private static let headerByteCount = 44

    /// Highest rate a RIFF header can carry that any decoder will accept.
    /// Well above every studio rate, and far below the `UInt32` field limit.
    public static let maximumSampleRate = 768_000
    /// Interleaved channel counts a WAVE `fmt ` chunk can describe.
    public static let maximumChannels = 64
    /// Sample depths the canonical PCM header describes.
    public static let supportedBitDepths: Set<Int> = [8, 16, 24, 32]

    /// Whether a RIFF/WAVE header can describe this format and payload.
    ///
    /// Checks every value that is narrowed or multiplied while the header is
    /// built, so a caller that passes this test cannot trap inside `wavData`.
    public static func isRepresentable(
        sampleRate: Int,
        channels: Int,
        bitsPerSample: Int,
        pcmByteCount: Int
    ) -> Bool {
        guard sampleRate > 0, sampleRate <= maximumSampleRate else { return false }
        guard channels > 0, channels <= maximumChannels else { return false }
        guard supportedBitDepths.contains(bitsPerSample) else { return false }
        guard pcmByteCount >= 0 else { return false }

        let blockAlign = channels * (bitsPerSample / 8)
        guard blockAlign > 0, blockAlign <= Int(UInt16.max) else { return false }
        let (byteRate, byteRateOverflowed) = sampleRate.multipliedReportingOverflow(by: blockAlign)
        guard !byteRateOverflowed, byteRate <= Int(UInt32.max) else { return false }

        guard pcmByteCount <= Int(UInt32.max) else { return false }
        let (riffSize, riffOverflowed) = pcmByteCount.addingReportingOverflow(headerByteCount - 8)
        guard !riffOverflowed, riffSize <= Int(UInt32.max) else { return false }
        return true
    }

    /// - Parameters:
    ///   - pcm: Raw interleaved sample bytes, little-endian.
    ///   - sampleRate: Frames per second, for example `24_000`.
    ///   - channels: Interleaved channel count.
    ///   - bitsPerSample: Bit depth of one sample, for example `16`.
    /// - Returns: The WAV bytes, or `nil` when the reported format cannot be
    ///   described by a RIFF header. Callers turn `nil` into an error rather
    ///   than writing a file that claims a format it does not hold.
    public static func wavData(
        pcm: Data,
        sampleRate: Int,
        channels: Int = 1,
        bitsPerSample: Int = 16
    ) -> Data? {
        guard isRepresentable(
            sampleRate: sampleRate,
            channels: channels,
            bitsPerSample: bitsPerSample,
            pcmByteCount: pcm.count
        ) else { return nil }

        let bytesPerSample = bitsPerSample / 8
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
