import Foundation
import CWindowsSupport

/// Decodes through installed Windows codecs on a dedicated native worker.
/// Completion waits for native destruction, so callers may safely remove the
/// temporary output after this function returns or throws.
public enum WindowsAudioConversion {
    public struct Output: Sendable {
        public let duration: TimeInterval
        public let sampleCount: UInt64
    }

    public static func convert(input: URL, output: URL) async throws -> Output {
        guard input.isFileURL, output.isFileURL,
              !input.path.utf8.contains(0), !output.path.utf8.contains(0) else {
            throw WindowsAudioConversionError("Choose local audio and output file paths.")
        }
        let operation = AudioConversionOperation(input: input, output: output)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
    }
}

public struct WindowsAudioConversionError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

private final class AudioConversionOperation: @unchecked Sendable {
    private let input: URL
    private let output: URL
    private let lock = NSLock()
    private var native: OpaquePointer?
    private var context: UnsafeMutableRawPointer?
    private var continuation: CheckedContinuation<WindowsAudioConversion.Output, Error>?
    private var cancelled = false
    private var completing = false

    init(input: URL, output: URL) { self.input = input; self.output = output }

    func start(_ continuation: CheckedContinuation<WindowsAudioConversion.Output, Error>) {
        var failure: Error?
        lock.withLock {
            self.continuation = continuation
            guard !cancelled else { failure = CancellationError(); return }
            var error = [CChar](repeating: 0, count: 1_024)
            let retained = Unmanaged.passRetained(self).toOpaque()
            native = input.path.withCString { input in
                output.path.withCString { output in
                    jsti_audio_conversion_create(input, output, audioConversionCompleted, retained, &error, error.count)
                }
            }
            guard let native else {
                Unmanaged<AudioConversionOperation>.fromOpaque(retained).release()
                failure = WindowsAudioConversionError(String(cString: error))
                return
            }
            context = retained
            if jsti_audio_conversion_start(native, &error, error.count) != 0 {
                failure = WindowsAudioConversionError(String(cString: error))
            }
        }
        if let failure { complete(.failure(failure)) }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            if let native { jsti_audio_conversion_cancel(native) }
        }
    }

    func complete(_ result: Result<WindowsAudioConversion.Output, Error>) {
        let shouldFinish = lock.withLock {
            guard !completing else { return false }
            completing = true
            return true
        }
        guard shouldFinish else { return }
        // A native completion runs on the worker being joined. Always dispatch
        // destruction elsewhere; retain the callback context until that join.
        DispatchQueue.global(qos: .utility).async { self.finish(result) }
    }

    private func finish(_ result: Result<WindowsAudioConversion.Output, Error>) {
        let owned = lock.withLock { () -> (OpaquePointer?, UnsafeMutableRawPointer?) in
            let owned = (native, context)
            native = nil
            context = nil
            return owned
        }
        var finalResult = result
        if let native = owned.0 {
            var error = [CChar](repeating: 0, count: 1_024)
            if jsti_audio_conversion_destroy(native, &error, error.count) == 0 {
                if let context = owned.1 { Unmanaged<AudioConversionOperation>.fromOpaque(context).release() }
            } else {
                // Native ownership remains alive on failure; releasing its
                // context could make a subsequent callback access freed memory.
                finalResult = .failure(WindowsAudioConversionError(String(cString: error)))
            }
        }
        let completion = lock.withLock { () -> CheckedContinuation<WindowsAudioConversion.Output, Error>? in
            // Once decoding succeeded, return ownership of its complete file
            // even if cancellation raced the callback. The caller can then
            // honour cancellation and remove that owned file safely.
            if cancelled, case .failure = finalResult { finalResult = .failure(CancellationError()) }
            let completion = continuation
            continuation = nil
            return completion
        }
        completion?.resume(with: finalResult)
    }
}

private func audioConversionCompleted(
    _ status: Int32, _ duration: Double, _ samples: UInt64,
    _ error: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let operation = Unmanaged<AudioConversionOperation>.fromOpaque(context).takeUnretainedValue()
    switch status {
    case 0:
        guard duration.isFinite, duration >= 0, samples <= (25_000_000 - 44) / 2,
              abs(duration - Double(samples) / 16_000) < 0.000_001 else {
            let error = WindowsAudioConversionError("Windows returned invalid decoded audio metadata.")
            operation.complete(.failure(error))
            return
        }
        operation.complete(.success(.init(duration: duration, sampleCount: samples)))
    case 1: operation.complete(.failure(CancellationError()))
    default:
        operation.complete(.failure(WindowsAudioConversionError(
            error.map(String.init(cString:)) ?? "Windows could not decode this audio file."
        )))
    }
}
