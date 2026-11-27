import Foundation

/// Errors thrown when validating or normalizing WAV audio returned by a voice studio.
public enum VoiceStudioWAVError: Error, LocalizedError, Equatable, Sendable {
    case emptyAudio
    case unsupportedFormat(String)
    case truncatedAudio
    case audioTooLarge

    public var errorDescription: String? {
        switch self {
        case .emptyAudio:
            "Voice studio returned an empty audio payload."
        case .unsupportedFormat(let detail):
            "Voice studio returned an unsupported audio format: \(detail)"
        case .truncatedAudio:
            "Voice studio returned truncated audio data."
        case .audioTooLarge:
            "Voice studio returned audio exceeding the maximum supported size."
        }
    }
}

/// Validates untrusted RIFF/WAVE payloads from local voice studios and normalizes them
/// to canonical 24 kHz mono 16-bit signed linear PCM WAV using `PCMWaveWriter`.
public enum VoiceStudioWAV {
    public static let canonicalSampleRate = 24_000
    /// Caps normalized output per request at 30 minutes of 24 kHz mono 16-bit audio.
    public static let maxOutputFrames = canonicalSampleRate * 60 * 30

    private static let pcmFormatTag: UInt16 = 1
    private static let ieeeFloatFormatTag: UInt16 = 3
    private static let extensibleFormatTag: UInt16 = 0xFFFE
    private static let extensibleSubformatTail: [UInt8] = [
        0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x80, 0x00, 0x00, 0xAA, 0x00, 0x38, 0x9B, 0x71
    ]
    private static let streamingSentinels: Set<UInt32> = [0, 0x7FFF_0000, 0xFFFF_FFFF]

    public struct NormalizedAudio: Equatable, Sendable {
        public let wavData: Data
        public let sampleRate: Int
        public let frameCount: Int

        public init(wavData: Data, sampleRate: Int, frameCount: Int) {
            self.wavData = wavData
            self.sampleRate = sampleRate
            self.frameCount = frameCount
        }

        public var duration: TimeInterval {
            Double(frameCount) / Double(sampleRate)
        }
    }

    private struct WaveFormat {
        let baseFormatTag: UInt16
        let channels: Int
        let sampleRate: Int
        let bitsPerSample: Int
    }

    public static func normalizeToMono24kPCM16(
        _ data: Data,
        targetSampleRate: Int = canonicalSampleRate
    ) throws -> NormalizedAudio {
        guard !data.isEmpty else { throw VoiceStudioWAVError.emptyAudio }
        guard targetSampleRate > 0, targetSampleRate <= PCMWaveWriter.maximumSampleRate else {
            throw VoiceStudioWAVError.unsupportedFormat("Invalid target sample rate.")
        }
        let (parsedFormat, payload) = try parseChunks(from: data)

        let monoSamples = try decodeMonoSamples(payload, format: parsedFormat)
        guard !monoSamples.isEmpty else { throw VoiceStudioWAVError.emptyAudio }

        let resampled = try resampleLinear(
            monoSamples,
            fromRate: parsedFormat.sampleRate,
            toRate: targetSampleRate
        )
        let pcm16 = encodePCM16(resampled)
        guard let wavData = PCMWaveWriter.wavData(
            pcm: pcm16,
            sampleRate: targetSampleRate,
            channels: 1,
            bitsPerSample: 16
        ) else {
            throw VoiceStudioWAVError.audioTooLarge
        }

        return NormalizedAudio(wavData: wavData, sampleRate: targetSampleRate, frameCount: resampled.count)
    }

    private static func parseChunks(from data: Data) throws -> (format: WaveFormat, payload: Data) {
        guard data.count >= 12,
              fourCC(data, at: 0) == "RIFF",
              fourCC(data, at: 8) == "WAVE"
        else {
            throw VoiceStudioWAVError.unsupportedFormat("Expected a RIFF/WAVE container.")
        }

        var format: WaveFormat?
        var pcmPayload: Data?
        var offset = 12

        while offset <= data.count - 8 {
            let chunkID = fourCC(data, at: offset)
            let rawSize = readUInt32(data, at: offset + 4)
            let chunkSize = Int(rawSize)
            let chunkStart = offset + 8
            let available = data.count - chunkStart

            if chunkID == "data" {
                let resolvedLength = streamingSentinels.contains(rawSize) ? available : chunkSize
                guard resolvedLength <= available else { throw VoiceStudioWAVError.truncatedAudio }
                pcmPayload = data.subdata(in: chunkStart..<(chunkStart + resolvedLength))
                break
            }

            guard chunkSize <= available else { throw VoiceStudioWAVError.truncatedAudio }
            if chunkID == "fmt " {
                format = try parseFormatChunk(data, start: chunkStart, length: chunkSize)
            }

            // RIFF chunks are word-aligned (odd lengths carry one trailing padding byte).
            let nextOffset = chunkStart + chunkSize + (chunkSize & 1)
            guard nextOffset > offset else { break }
            offset = nextOffset
        }

        guard let parsedFormat = format else {
            throw VoiceStudioWAVError.unsupportedFormat("Missing RIFF fmt chunk.")
        }
        guard let payload = pcmPayload else {
            throw VoiceStudioWAVError.unsupportedFormat("Missing RIFF data chunk.")
        }
        return (parsedFormat, payload)
    }

    private static func parseFormatChunk(_ data: Data, start: Int, length: Int) throws -> WaveFormat {
        guard length >= 16 else {
            throw VoiceStudioWAVError.unsupportedFormat("fmt chunk is too short.")
        }
        let rawTag = readUInt16(data, at: start)
        let channels = Int(readUInt16(data, at: start + 2))
        let sampleRate = Int(readUInt32(data, at: start + 4))
        let bitsPerSample = Int(readUInt16(data, at: start + 14))

        guard channels > 0, channels <= PCMWaveWriter.maximumChannels else {
            throw VoiceStudioWAVError.unsupportedFormat("Unsupported channel count \(channels).")
        }
        guard sampleRate >= 4_000, sampleRate <= 192_000 else {
            throw VoiceStudioWAVError.unsupportedFormat("Unsupported sample rate \(sampleRate) Hz.")
        }

        let resolvedTag: UInt16
        if rawTag == extensibleFormatTag {
            guard length >= 40 else {
                throw VoiceStudioWAVError.unsupportedFormat("Truncated extensible fmt chunk.")
            }
            let subTag = readUInt16(data, at: start + 24)
            let tailStart = start + 26
            let tail = Array(data[tailStart..<(tailStart + 14)])
            guard tail == extensibleSubformatTail else {
                throw VoiceStudioWAVError.unsupportedFormat("Unsupported extensible WAVE subformat.")
            }
            resolvedTag = subTag
        } else {
            resolvedTag = rawTag
        }

        switch (resolvedTag, bitsPerSample) {
        case (pcmFormatTag, 8), (pcmFormatTag, 16), (pcmFormatTag, 24), (pcmFormatTag, 32):
            break
        case (ieeeFloatFormatTag, 32), (ieeeFloatFormatTag, 64):
            break
        default:
            throw VoiceStudioWAVError.unsupportedFormat(
                "Unsupported WAVE encoding tag \(resolvedTag) at \(bitsPerSample)-bit depth."
            )
        }

        return WaveFormat(
            baseFormatTag: resolvedTag,
            channels: channels,
            sampleRate: sampleRate,
            bitsPerSample: bitsPerSample
        )
    }

    private static func decodeMonoSamples(_ payload: Data, format: WaveFormat) throws -> [Double] {
        let bytesPerSample = format.bitsPerSample / 8
        let frameStride = bytesPerSample * format.channels
        guard frameStride > 0 else { throw VoiceStudioWAVError.unsupportedFormat("Zero frame stride.") }
        let frameCount = payload.count / frameStride
        guard frameCount > 0 else { return [] }

        var result = [Double]()
        result.reserveCapacity(frameCount)

        for frameIndex in 0..<frameCount {
            let frameBase = frameIndex * frameStride
            var sum = 0.0
            for channelIndex in 0..<format.channels {
                let sampleOffset = frameBase + channelIndex * bytesPerSample
                sum += decodeSample(payload, at: sampleOffset, format: format)
            }
            result.append(sum / Double(format.channels))
        }
        return result
    }

    private static func decodeSample(_ data: Data, at offset: Int, format: WaveFormat) -> Double {
        let base = data.startIndex + offset
        switch (format.baseFormatTag, format.bitsPerSample) {
        case (pcmFormatTag, 8):
            // 8-bit WAVE PCM is unsigned [0, 255] with silence at 128.
            return (Double(data[base]) - 128.0) / 128.0
        case (pcmFormatTag, 16):
            let raw = Int16(bitPattern: readUInt16(data, at: offset))
            return Double(raw) / 32_768.0
        case (pcmFormatTag, 24):
            let low = Int32(data[base])
            let mid = Int32(data[base + 1]) << 8
            let high = Int32(Int8(bitPattern: data[base + 2])) << 16
            let signed24 = low | mid | high
            return Double(signed24) / 8_388_608.0
        case (pcmFormatTag, 32):
            let raw = Int32(bitPattern: readUInt32(data, at: offset))
            return Double(raw) / 2_147_483_648.0
        case (ieeeFloatFormatTag, 32):
            return Double(Float(bitPattern: readUInt32(data, at: offset)))
        case (ieeeFloatFormatTag, 64):
            let raw = UInt64(readUInt32(data, at: offset))
                | (UInt64(readUInt32(data, at: offset + 4)) << 32)
            return Double(bitPattern: raw)
        default:
            return 0.0
        }
    }

    private static func resampleLinear(
        _ samples: [Double],
        fromRate: Int,
        toRate: Int
    ) throws -> [Double] {
        guard fromRate != toRate else {
            guard samples.count <= maxOutputFrames else { throw VoiceStudioWAVError.audioTooLarge }
            return samples
        }
        let ratio = Double(fromRate) / Double(toRate)
        let targetCount = max(1, Int((Double(samples.count) * Double(toRate) / Double(fromRate)).rounded()))
        guard targetCount <= maxOutputFrames else { throw VoiceStudioWAVError.audioTooLarge }

        var output = [Double]()
        output.reserveCapacity(targetCount)
        let lastIndex = samples.count - 1
        for index in 0..<targetCount {
            let position = Double(index) * ratio
            let lower = min(lastIndex, Int(position))
            let upper = min(lastIndex, lower + 1)
            let fraction = position - Double(lower)
            let interpolated = samples[lower] + (samples[upper] - samples[lower]) * fraction
            output.append(interpolated)
        }
        return output
    }

    private static func encodePCM16(_ samples: [Double]) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for sample in samples {
            let finiteSample = sample.isFinite ? min(max(sample, -1.0), 1.0) : 0.0
            let scaled = finiteSample >= 1.0 ? 32_767.0 : (finiteSample * 32_768.0).rounded()
            let clamped = Int16(min(max(scaled, Double(Int16.min)), Double(Int16.max)))
            var little = UInt16(bitPattern: clamped).littleEndian
            withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) }
        }
        return pcm
    }

    private static func fourCC(_ data: Data, at offset: Int) -> String {
        let base = data.startIndex + offset
        return String(bytes: data[base..<(base + 4)], encoding: .ascii) ?? ""
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }
}
