import Foundation

/// Decoded mono floating-point audio buffer used across portable trimming, quality gating and WAV export.
public struct VoiceProfilePCMBuffer: Equatable, Sendable {
    public let samples: [Float]
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }

    public var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(samples.count) / Double(sampleRate)
    }

    public func sliced(from startSeconds: Double, to endSeconds: Double) -> VoiceProfilePCMBuffer {
        guard sampleRate > 0, !samples.isEmpty else {
            return VoiceProfilePCMBuffer(samples: [], sampleRate: sampleRate)
        }
        let clampedStart = max(0, min(samples.count, Int((startSeconds * Double(sampleRate)).rounded(.down))))
        let clampedEnd = max(clampedStart, min(samples.count, Int((endSeconds * Double(sampleRate)).rounded(.up))))
        return VoiceProfilePCMBuffer(samples: Array(samples[clampedStart..<clampedEnd]), sampleRate: sampleRate)
    }
}

/// Errors thrown when reading, converting or writing canonical voice-profile WAV audio.
public enum VoiceProfileWAVCodecError: LocalizedError, Equatable, Sendable {
    case fileTooLarge(Int)
    case invalidWAVHeader
    case unsupportedWAVFormat(String)
    case emptyAudio
    case encodingFailed

    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let bytes):
            "Audio file exceeds the \(bytes / (1024 * 1024)) MB size limit."
        case .invalidWAVHeader:
            "The WAV file header is incomplete or damaged."
        case .unsupportedWAVFormat(let detail):
            "Unsupported WAV format: \(detail)"
        case .emptyAudio:
            "The audio file contains no samples."
        case .encodingFailed:
            "Could not encode the clip as a mono PCM WAV file."
        }
    }
}

/// Portable RIFF/WAVE decoder, mono downmixer, linear/box resampler and PCM16 WAV encoder.
public enum VoiceProfileWAVCodec {
    public static let maximumInputBytes = 128 * 1024 * 1024

    private struct FormatChunk {
        let audioFormat: UInt16
        let channels: Int
        let sampleRate: Int
        let bitsPerSample: Int
        let effectiveTag: UInt16
    }

    public static func decodeWAV(at url: URL) throws -> VoiceProfilePCMBuffer {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize <= UInt64(maximumInputBytes) else {
            throw VoiceProfileWAVCodecError.fileTooLarge(maximumInputBytes)
        }
        try handle.seek(toOffset: 0)
        guard let data = try handle.readToEnd() else {
            throw VoiceProfileWAVCodecError.invalidWAVHeader
        }
        return try decodeWAV(data)
    }

    public static func decodeWAV(_ data: Data) throws -> VoiceProfilePCMBuffer {
        let data = data.startIndex == 0 ? data : Data(data)
        guard data.count <= maximumInputBytes else {
            throw VoiceProfileWAVCodecError.fileTooLarge(maximumInputBytes)
        }
        guard data.count >= 44,
              asciiString(in: data, offset: 0, length: 4) == "RIFF",
              asciiString(in: data, offset: 8, length: 4) == "WAVE" else {
            throw VoiceProfileWAVCodecError.invalidWAVHeader
        }

        let (formatChunk, pcmRange) = try scanChunks(in: data)
        guard let formatChunk, let pcmRange else {
            throw VoiceProfileWAVCodecError.invalidWAVHeader
        }
        guard formatChunk.channels > 0,
              formatChunk.channels <= PCMWaveWriter.maximumChannels,
              formatChunk.sampleRate > 0,
              formatChunk.sampleRate <= PCMWaveWriter.maximumSampleRate else {
            throw VoiceProfileWAVCodecError.unsupportedWAVFormat("invalid channel count or sample rate")
        }

        let samples = try decodeSamples(data: data, range: pcmRange, format: formatChunk)
        guard !samples.isEmpty else {
            throw VoiceProfileWAVCodecError.emptyAudio
        }
        return VoiceProfilePCMBuffer(samples: samples, sampleRate: formatChunk.sampleRate)
    }

    public static func resample(
        _ buffer: VoiceProfilePCMBuffer,
        to targetFormat: VoiceProfileAudioFormat
    ) -> VoiceProfilePCMBuffer {
        let targetRate = targetFormat.sampleRate
        guard buffer.sampleRate > 0, !buffer.samples.isEmpty else {
            return VoiceProfilePCMBuffer(samples: [], sampleRate: targetRate)
        }
        guard buffer.sampleRate != targetRate else { return buffer }

        let sourceCount = buffer.samples.count
        let ratio = Double(buffer.sampleRate) / Double(targetRate)
        let targetCount = max(1, Int((Double(sourceCount) / ratio).rounded()))
        var output = [Float](repeating: 0, count: targetCount)

        if ratio > 1.0 {
            // Simple box average over the source footprint reduces aliasing when downsampling.
            let halfSpan = ratio * 0.5
            for outIndex in 0..<targetCount {
                let center = (Double(outIndex) + 0.5) * ratio - 0.5
                let start = max(0, Int((center - halfSpan).rounded(.down)))
                let end = min(sourceCount - 1, Int((center + halfSpan).rounded(.up)))
                var accumulator: Float = 0
                for srcIndex in start...end {
                    accumulator += buffer.samples[srcIndex]
                }
                output[outIndex] = accumulator / Float(end - start + 1)
            }
        } else {
            for outIndex in 0..<targetCount {
                let sourcePosition = Double(outIndex) * ratio
                let lower = min(sourceCount - 1, Int(sourcePosition))
                let upper = min(sourceCount - 1, lower + 1)
                let fraction = Float(sourcePosition - Double(lower))
                output[outIndex] = buffer.samples[lower] * (1 - fraction) + buffer.samples[upper] * fraction
            }
        }
        return VoiceProfilePCMBuffer(samples: output, sampleRate: targetRate)
    }

    public static func encodeWAV(
        _ buffer: VoiceProfilePCMBuffer,
        format: VoiceProfileAudioFormat = .pcm24k
    ) throws -> Data {
        let normalized = resample(buffer, to: format)
        guard !normalized.samples.isEmpty else {
            throw VoiceProfileWAVCodecError.emptyAudio
        }
        let pcmData = normalized.samples.withUnsafeBufferPointer { pointer -> Data in
            guard let base = pointer.baseAddress else { return Data() }
            return PCM16Converter.data(from: base, frameCount: pointer.count)
        }
        guard let wav = PCMWaveWriter.wavData(
            pcm: pcmData,
            sampleRate: format.sampleRate,
            channels: format.channels,
            bitsPerSample: format.bitsPerSample
        ) else {
            throw VoiceProfileWAVCodecError.encodingFailed
        }
        return wav
    }

    private static func scanChunks(in data: Data) throws -> (FormatChunk?, Range<Int>?) {
        var offset = 12
        var formatChunk: FormatChunk?
        var pcmRange: Range<Int>?

        while offset + 8 <= data.count {
            let chunkID = asciiString(in: data, offset: offset, length: 4)
            let chunkSize = Int(uint32(in: data, offset: offset + 4))
            let bodyStart = offset + 8
            guard bodyStart + chunkSize <= data.count else {
                throw VoiceProfileWAVCodecError.invalidWAVHeader
            }
            if chunkID == "fmt " {
                formatChunk = try parseFormatChunk(in: data, start: bodyStart, size: chunkSize)
            } else if chunkID == "data" && pcmRange == nil {
                pcmRange = bodyStart..<(bodyStart + chunkSize)
            }
            let paddedSize = chunkSize + (chunkSize % 2)
            offset = bodyStart + paddedSize
        }
        return (formatChunk, pcmRange)
    }

    private static func parseFormatChunk(in data: Data, start: Int, size: Int) throws -> FormatChunk {
        guard size >= 16 else { throw VoiceProfileWAVCodecError.invalidWAVHeader }
        let audioFormat = uint16(in: data, offset: start)
        let channels = Int(uint16(in: data, offset: start + 2))
        let sampleRate = Int(uint32(in: data, offset: start + 4))
        let bitsPerSample = Int(uint16(in: data, offset: start + 14))
        var effectiveTag = audioFormat
        if audioFormat == 0xFFFE, size >= 40 {
            effectiveTag = uint16(in: data, offset: start + 24)
        }
        return FormatChunk(
            audioFormat: audioFormat,
            channels: channels,
            sampleRate: sampleRate,
            bitsPerSample: bitsPerSample,
            effectiveTag: effectiveTag
        )
    }

    private static func decodeSamples(
        data: Data,
        range: Range<Int>,
        format: FormatChunk
    ) throws -> [Float] {
        let bytesPerSample = format.bitsPerSample / 8
        let blockAlign = format.channels * bytesPerSample
        guard bytesPerSample > 0, format.bitsPerSample % 8 == 0, blockAlign > 0 else {
            throw VoiceProfileWAVCodecError.unsupportedWAVFormat("\(format.bitsPerSample)-bit")
        }
        let availableBytes = range.count - (range.count % blockAlign)
        let frameCount = availableBytes / blockAlign
        guard frameCount > 0 else { throw VoiceProfileWAVCodecError.emptyAudio }

        var mono = [Float](repeating: 0, count: frameCount)
        let channelScale = 1.0 / Float(format.channels)

        for frameIndex in 0..<frameCount {
            let frameOffset = range.lowerBound + frameIndex * blockAlign
            var sum: Float = 0
            for channelIndex in 0..<format.channels {
                let sampleOffset = frameOffset + channelIndex * bytesPerSample
                sum += try decodeSample(data: data, offset: sampleOffset, format: format)
            }
            mono[frameIndex] = max(-1.0, min(1.0, sum * channelScale))
        }
        return mono
    }

    private static func decodeSample(
        data: Data,
        offset: Int,
        format: FormatChunk
    ) throws -> Float {
        switch (format.effectiveTag, format.bitsPerSample) {
        case (1, 8):
            return (Float(data[offset]) - 128.0) / 128.0
        case (1, 16):
            let raw = Int16(bitPattern: uint16(in: data, offset: offset))
            return Float(raw) / 32_768.0
        case (1, 24):
            let low = Int32(data[offset])
            let mid = Int32(data[offset + 1]) << 8
            let high = Int32(Int8(bitPattern: data[offset + 2])) << 16
            return Float(low | mid | high) / 8_388_608.0
        case (1, 32):
            let raw = Int32(bitPattern: uint32(in: data, offset: offset))
            return Float(Double(raw) / 2_147_483_648.0)
        case (3, 32):
            let raw = Float(bitPattern: uint32(in: data, offset: offset))
            return raw.isFinite ? raw : 0
        default:
            throw VoiceProfileWAVCodecError.unsupportedWAVFormat(
                "tag \(format.effectiveTag), \(format.bitsPerSample)-bit"
            )
        }
    }

    private static func asciiString(in data: Data, offset: Int, length: Int) -> String? {
        String(bytes: data[offset..<(offset + length)], encoding: .ascii)
    }

    private static func uint16(in data: Data, offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func uint32(in data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
