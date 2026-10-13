import Foundation
#if canImport(AVFoundation) && !SPEAK_PORTABLE_CORE
import AVFoundation
#endif

/// Shared mono 16 kHz PCM16 WAV preparation. Portable hosts validate native
/// capture without decoding; Apple can convert other containers in process.
/// Both paths bound decoded bytes before appending them.
public enum NativePCM16WAVReader {
    static let sampleRate = 16_000
    private static let headerSize = 44
    private static let bytesPerSecond = sampleRate * 2

    struct PreparedAudio {
        let data: Data
        let duration: TimeInterval
    }

    /// Apple decodes in process; portable hosts validate their native capture
    /// format. Both paths enforce the same decoded-size and duration limits.
    static func prepareWAV(
        at url: URL, maximumDuration: TimeInterval, maximumBytes: Int
    ) async throws -> PreparedAudio {
        #if canImport(AVFoundation) && !SPEAK_PORTABLE_CORE
        return try convertWAV(at: url, maximumDuration: maximumDuration, maximumBytes: maximumBytes)
        #else
        return try prepare(at: url, maximumDuration: maximumDuration, maximumBytes: maximumBytes)
        #endif
    }

    #if canImport(AVFoundation) && !SPEAK_PORTABLE_CORE
    private static func convertWAV(
        at url: URL, maximumDuration: TimeInterval, maximumBytes: Int
    ) throws -> PreparedAudio {
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw PreparationError.emptyInput }
        guard maximumDuration.isFinite, duration <= maximumDuration, maximumBytes > headerSize else {
            throw PreparationError.limitExceeded
        }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true
        ), let converter = AVAudioConverter(from: file.processingFormat, to: format),
        let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8_192),
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192) else {
            throw PreparationError.unsupportedFormat
        }
        let pcm = try convert(
            file: file, converter: converter, input: input, output: output, maximumBytes: maximumBytes
        )
        try Task.checkCancellation()
        guard !pcm.isEmpty, let wav = PCMWaveWriter.wavData(pcm: pcm, sampleRate: sampleRate) else {
            throw PreparationError.emptyInput
        }
        return PreparedAudio(data: wav, duration: Double(pcm.count) / Double(bytesPerSecond))
    }

    private static func convert(
        file: AVAudioFile, converter: AVAudioConverter, input: AVAudioPCMBuffer,
        output: AVAudioPCMBuffer, maximumBytes: Int
    ) throws -> Data {
        var pcm = Data()
        var finished = false
        while !finished {
            try Task.checkCancellation()
            var readError: Error?
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard file.framePosition < file.length else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do {
                    try file.read(into: input)
                    inputStatus.pointee = input.frameLength == 0 ? .endOfStream : .haveData
                    return input.frameLength == 0 ? nil : input
                } catch {
                    readError = error
                    inputStatus.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            guard status != .error else { throw PreparationError.unsupportedFormat }
            let buffer = output.audioBufferList.pointee.mBuffers
            let count = Int(output.frameLength) * 2
            guard pcm.count + count + headerSize < maximumBytes else { throw PreparationError.limitExceeded }
            if count > 0 {
                guard let bytes = buffer.mData else { throw PreparationError.invalidContainer }
                pcm.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
            }
            finished = status == .endOfStream
            guard finished || count > 0 else { throw PreparationError.invalidContainer }
        }
        return pcm
    }
    #endif

    /// Reads only the 44-byte header and file size. Platform adapters can skip
    /// decoding recordings that already match the shared provider input format.
    public static func canonicalDuration(at url: URL) throws -> TimeInterval {
        try Task.checkCancellation()
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        guard size >= UInt64(headerSize) else { throw PreparationError.invalidContainer }
        try input.seek(toOffset: 0)
        guard let header = try input.read(upToCount: headerSize), header.count == headerSize else {
            throw PreparationError.invalidContainer
        }
        let payloadSize = size - UInt64(headerSize)
        try validate(header: header, size: size, payloadSize: payloadSize)
        guard payloadSize > 0 else { throw PreparationError.emptyInput }
        return Double(payloadSize) / Double(bytesPerSecond)
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
