import Foundation

/// Reads the canonical WAV produced by native desktop capture without decoding
/// or resampling. Other containers and WAV layouts need a platform converter.
/// Bytes are bounded before allocation, then checked against the actual file.
enum NativePCM16WAVReader {
    static let sampleRate = 16_000
    private static let headerSize = 44
    private static let bytesPerSecond = sampleRate * 2

    struct PreparedAudio {
        let data: Data
        let duration: TimeInterval
    }

    static func prepare(
        at url: URL, maximumDuration: TimeInterval, maximumBytes: Int
    ) throws -> PreparedAudio {
        try Task.checkCancellation()
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        guard size >= UInt64(headerSize) else { throw PreparationError.invalidContainer }
        guard maximumBytes > headerSize, size < UInt64(maximumBytes) else {
            throw PreparationError.limitExceeded
        }
        let payloadSize = size - UInt64(headerSize)
        let duration = Double(payloadSize) / Double(bytesPerSecond)
        guard maximumDuration.isFinite, maximumDuration >= 0, duration <= maximumDuration else {
            throw PreparationError.limitExceeded
        }
        try input.seek(toOffset: 0)
        guard let header = try input.read(upToCount: headerSize), header.count == headerSize else {
            throw PreparationError.invalidContainer
        }
        try validate(header: header, size: size, payloadSize: payloadSize)
        guard payloadSize > 0 else { throw PreparationError.emptyInput }

        var audio = header
        audio.reserveCapacity(Int(size))
        while audio.count < Int(size) {
            try Task.checkCancellation()
            let remaining = Int(size) - audio.count
            guard let chunk = try input.read(upToCount: min(65_536, remaining)), !chunk.isEmpty else {
                throw PreparationError.invalidContainer
            }
            audio.append(chunk)
        }
        // A recording modified while it was read is not a valid frozen upload.
        guard try input.read(upToCount: 1)?.isEmpty != false else {
            throw PreparationError.invalidContainer
        }
        try Task.checkCancellation()
        return PreparedAudio(data: audio, duration: duration)
    }

    private static func validate(header: Data, size: UInt64, payloadSize: UInt64) throws {
        guard let expected = PCMWaveWriter.wavData(pcm: Data(), sampleRate: sampleRate) else {
            throw PreparationError.invalidContainer
        }
        // Match RIFF/WAVE, PCM format, rate, channels, bit depth, block alignment
        // and chunk layout. Only the two length fields vary with the recording.
        for index in 0..<headerSize where !(4..<8).contains(index) && !(40..<44).contains(index) {
            guard header[index] == expected[index] else { throw PreparationError.unsupportedFormat }
        }
        guard integer(in: header, at: 4) + 8 == size,
              integer(in: header, at: 40) == payloadSize,
              payloadSize % 2 == 0 else { throw PreparationError.invalidContainer }
    }

    private static func integer(in data: Data, at offset: Int) -> UInt64 {
        data[offset..<(offset + 4)].enumerated().reduce(0) { value, byte in
            value | (UInt64(byte.element) << (byte.offset * 8))
        }
    }

    enum PreparationError: LocalizedError, Equatable {
        case unsupportedFormat
        case invalidContainer
        case emptyInput
        case limitExceeded

        var errorDescription: String? {
            switch self {
            case .unsupportedFormat:
                return "This build accepts standard 16 kHz mono 16-bit PCM WAV audio for this provider. "
                    + "Record in the app or convert the imported file to that format."
            case .invalidContainer:
                return "The WAV recording is incomplete or its header does not match its audio data."
            case .emptyInput:
                return "The recording contains no audio frames."
            case .limitExceeded:
                return "The recording exceeds the provider's audio preparation limit."
            }
        }
    }
}
