import Foundation
import SpeakCore

/// Appends capture frames directly to disk, with constant memory use. The native
/// capture worker calls append after releasing its WASAPI packet; never on a UI
/// or system audio callback. finish must follow the native worker's stop/join.
public final class PCMRecordingFile: @unchecked Sendable {
    public let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var byteCount = 0
    private var closed = false
    private var writeFailure: Error?
    private var containsSignal = false

    public var isDigitalSilence: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !containsSignal
    }
    public static let sampleRate = 16_000
    // Bound both RIFF sizes and the duration of an accidentally abandoned run.
    public static let maximumBytes = sampleRate * 2 * 60 * 60 * 2

    public init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: try Self.header(payloadBytes: 0)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        self.handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    public func append(_ data: Data) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw RecordingFileError.alreadyClosed }
        if let writeFailure { throw writeFailure }
        guard data.count % 2 == 0 else { throw RecordingFileError.invalidPCM }
        guard data.count <= Self.maximumBytes - byteCount else { throw RecordingFileError.durationLimit }
        do {
            try handle.write(contentsOf: data)
            byteCount += data.count
            containsSignal = containsSignal || data.contains(where: { $0 != 0 })
        } catch {
            writeFailure = error
            throw error
        }
    }

    @discardableResult
    public func finish() throws -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw RecordingFileError.alreadyClosed }
        defer { closed = true; try? handle.close() }
        // Generate only the header: patch payload lengths without copying audio.
        let header = try Self.header(payloadBytes: byteCount)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header)
        try handle.synchronize()
        if let writeFailure { throw writeFailure }
        return Double(byteCount) / Double(Self.sampleRate * 2)
    }

    /// Repairs only our canonical PCM container after an interrupted recording.
    /// Actual payload bytes are authoritative; no audio is decoded or discarded.
    @discardableResult
    public static func recoverInterruptedFile(at url: URL) throws -> TimeInterval {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size >= 44, size - 44 <= UInt64(maximumBytes), (size - 44) % 2 == 0 else {
            throw RecordingFileError.invalidPCM
        }
        try handle.seek(toOffset: 0)
        guard let current = try handle.read(upToCount: 44), current.count == 44 else {
            throw RecordingFileError.invalidPCM
        }
        let expected = try header(payloadBytes: 0)
        // Only the RIFF/data lengths may differ from the format we own.
        for index in 0..<44 where !(4..<8).contains(index) && !(40..<44).contains(index) {
            guard current[index] == expected[index] else { throw RecordingFileError.invalidPCM }
        }
        let bytes = Int(size - 44)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(payloadBytes: bytes))
        try handle.synchronize()
        return Double(bytes) / Double(sampleRate * 2)
    }

    private static func header(payloadBytes: Int) throws -> Data {
        guard var header = PCMWaveWriter.wavData(pcm: Data(), sampleRate: sampleRate) else {
            throw RecordingFileError.invalidPCM
        }
        for (offset, size) in [(4, payloadBytes + 36), (40, payloadBytes)] {
            var value = UInt32(size).littleEndian
            withUnsafeBytes(of: &value) { header.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        return header
    }
}

public enum RecordingFileError: LocalizedError {
    case alreadyClosed
    case invalidPCM
    case durationLimit

    public var errorDescription: String? {
        switch self {
        case .alreadyClosed: return "The recording file is already closed."
        case .invalidPCM: return "The microphone returned an invalid audio frame."
        case .durationLimit: return "Recording reached the two-hour limit. Stop and start a new recording."
        }
    }
}
