import Foundation
import SpeakCore
import CLinuxSupport

/// Converts an imported file to canonical 16 kHz mono PCM16 WAV with
/// GStreamer, off the caller's thread and cancellable. The converter owns
/// partial output: it creates `output` new (0600) and removes it on failure or
/// cancellation, never touching an existing file.
public enum LinuxAudioConversion {
    public static let sampleRate = 16_000
    /// Matches the upload cap: at most 25 MB of WAV.
    static let maximumBytes = 25_000_000 - 44

    private final class Collector: @unchecked Sendable {
        var pcm = Data()
        var overflow = false
    }

    private final class Flag: @unchecked Sendable {
        let pointer = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        init() { pointer.initialize(to: 0) }
        deinit { pointer.deallocate() }
        func set() { pointer.pointee = 1 }
    }

    /// Returns the converted duration in seconds.
    public static func convert(input: URL, output: URL) async throws -> TimeInterval {
        let cancel = Flag()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Thread.detachNewThread {
                    continuation.resume(with: Result { try decode(input: input, output: output, cancel: cancel) })
                }
            }
        } onCancel: {
            cancel.set()
        }
    }

    private static func decode(input: URL, output: URL, cancel: Flag) throws -> TimeInterval {
        let collector = Collector()
        var error = [CChar](repeating: 0, count: 1024)
        let result = withExtendedLifetime(collector) {
            jsti_audio_decode(input.path, UInt32(sampleRate), { samples, count, context in
                guard let samples, let context else { return }
                let collector = Unmanaged<Collector>.fromOpaque(context).takeUnretainedValue()
                guard collector.pcm.count + count * 2 <= LinuxAudioConversion.maximumBytes else { collector.overflow = true; return }
                collector.pcm.append(UnsafeBufferPointer(start: samples, count: count))
            }, Unmanaged.passUnretained(collector).toOpaque(), cancel.pointer, &error, error.count)
        }
        if result == 1 { throw CancellationError() }
        guard result == 0 else { throw LinuxNativeError(message: String(cString: error)) }
        guard !collector.overflow else {
            throw LinuxNativeError(message: "The converted audio exceeds the 25 MB upload cap.")
        }
        guard !collector.pcm.isEmpty, let wave = PCMWaveWriter.wavData(pcm: collector.pcm, sampleRate: sampleRate) else {
            throw LinuxNativeError(message: "This audio file contains no decodable audio.")
        }
        try LinuxFiles.createPrivateFile(output)
        do {
            let handle = try FileHandle(forWritingTo: output)
            defer { try? handle.close() }
            try handle.write(contentsOf: wave)
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return Double(collector.pcm.count / 2) / Double(sampleRate)
    }
}
