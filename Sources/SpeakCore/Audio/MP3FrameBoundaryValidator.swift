import Foundation

/// A bounded framing check, independent of the native decoder's EOF tolerance.
/// It detects incomplete ID3 headers/tags and Layer III frames, not damaged audio
/// within a complete frame or every corruption that an MP3 decoder may conceal.
struct MP3FrameBoundaryValidator {
    private struct StreamFormat: Equatable {
        let version: UInt8
        let sampleRate: Int
        let channels: Int
    }

    static let maximumMetadataBytes = 256 * 1024
    private var pending = Data()
    private var metadataRemaining = 0
    private var isBeginning = true
    private var frameBytesRemaining = 0
    private(set) var frameCount = 0
    private var trailer = false
    private var format: StreamFormat?

    mutating func append(_ data: Data) throws {
        guard data.count <= 1024 else { throw OpenRouterAudioError.invalidResponse }
        pending.append(data)
        while try consume() { }
    }

    mutating func finish() throws {
        while try consume() { }
        let completeTrailer = trailer && pending.count == 128
        guard frameCount > 0, metadataRemaining == 0, frameBytesRemaining == 0,
              pending.isEmpty || completeTrailer else { throw OpenRouterAudioError.invalidResponse }
    }

    private mutating func consume() throws -> Bool {
        if metadataRemaining > 0 {
            let count = min(metadataRemaining, pending.count)
            pending.removeFirst(count)
            metadataRemaining -= count
            return count > 0
        }
        if frameBytesRemaining > 0 {
            let count = min(frameBytesRemaining, pending.count)
            pending.removeFirst(count)
            frameBytesRemaining -= count
            if frameBytesRemaining == 0 { frameCount += 1 }
            return count > 0
        }
        if trailer {
            guard pending.count <= 128 else { throw OpenRouterAudioError.invalidResponse }
            return false
        }
        if isBeginning {
            return try consumeBeginning()
        }
        guard pending.count >= 3 else { return false }
        if frameCount > 0, pending.prefix(3) == Data("TAG".utf8) {
            trailer = true
            return true
        }
        guard pending.count >= 4 else { return false }
        try beginFrame()
        return true
    }

    private mutating func beginFrame() throws {
        let frame = try Self.frameInfo(Array(pending.prefix(4)))
        if let format {
            guard format == frame.format else { throw OpenRouterAudioError.invalidResponse }
        } else {
            format = frame.format
        }
        frameBytesRemaining = frame.length
    }

    private mutating func consumeBeginning() throws -> Bool {
        guard pending.count >= 3 else { return false }
        if pending.prefix(3) == Data("ID3".utf8) {
            guard pending.count >= 10 else { return false }
            let header = Array(pending.prefix(10))
            guard (2...4).contains(header[3]), header[4] != 255,
                  header[6...9].allSatisfy({ $0 < 128 }) else { throw OpenRouterAudioError.invalidResponse }
            let length = header[6...9].reduce(0) { ($0 << 7) | Int($1) }
            let footer = header[3] == 4 && header[5] & 0x10 != 0 ? 10 : 0
            guard length + footer + 10 <= Self.maximumMetadataBytes else {
                throw OpenRouterAudioError.responseTooLarge
            }
            pending.removeFirst(10)
            metadataRemaining = length + footer
        }
        isBeginning = false
        return true
    }

    private static func frameInfo(_ header: [UInt8]) throws -> (length: Int, format: StreamFormat) {
        let version = (header[1] >> 3) & 3
        let layer = (header[1] >> 1) & 3
        let rateIndex = Int((header[2] >> 2) & 3)
        let bitrateIndex = Int(header[2] >> 4)
        guard header[0] == 255, header[1] & 0xE0 == 0xE0, version != 1, layer == 1,
              rateIndex < 3, (1...14).contains(bitrateIndex), header[3] & 3 != 2 else {
            // Free-format streams are outside this bounded incremental path.
            throw OpenRouterAudioError.invalidResponse
        }
        let rates = [44_100, 48_000, 32_000]
        let bitrates = version == 3
            ? [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320]
            : [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]
        let sampleRate = rates[rateIndex] / (version == 3 ? 1 : version == 2 ? 2 : 4)
        let coefficient = version == 3 ? 144_000 : 72_000
        let length = coefficient * bitrates[bitrateIndex] / sampleRate + Int((header[2] >> 1) & 1)
        return (length, StreamFormat(version: version, sampleRate: sampleRate, channels: header[3] >> 6 == 3 ? 1 : 2))
    }
}
