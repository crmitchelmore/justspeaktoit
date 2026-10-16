import CLinuxSupport
import Foundation
import SpeakCore
import SpeakDesktop
import SpeakFeedbackResources

public struct LinuxRecordingFeedbackLoader: DesktopRecordingFeedbackLoader {
    public init() {}

    public static func checkAssets(profile: RecordingFeedbackProfile) async throws -> Int {
        let paths = try RecordingFeedbackSound.allCases.map {
            try RecordingFeedbackResources.url(for: $0, profile: profile).path
        }

        return try await Task.detached {
            for path in paths {
                var error = [CChar](repeating: 0, count: 512)
                guard jsti_recording_feedback_check_asset(path, &error, error.count) == 0 else {
                    throw LinuxFeedbackError(message: String(cString: error))
                }
            }
            return paths.count
        }.value
    }

    /// Measures queue admission on a real endpoint, not audible latency.
    public static func checkNativeOutput(profile: RecordingFeedbackProfile) async throws -> [Double] {
        let native = try await LinuxRecordingFeedbackLoader().prepareNative(profile: profile)
        do {
            var latencies: [Double] = []
            for sound in RecordingFeedbackSound.allCases {
                try native.play(sound, gain: 0.49)
                let deadline = ContinuousClock.now.advanced(by: .milliseconds(100))
                var latency = native.queuedLatency()
                while latency == 0, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(1))
                    latency = native.queuedLatency()
                }
                guard latency > 0, latency <= 0.1 else {
                    throw LinuxFeedbackError(message: "Prepared recording sound did not queue samples within 100 ms.")
                }
                latencies.append(latency)
                native.stop()
            }
            await native.close()
            return latencies
        } catch {
            await native.close()
            throw error
        }
    }

    public func prepare(profile: RecordingFeedbackProfile) async throws -> any DesktopRecordingFeedbackOutput {
        try await prepareNative(profile: profile)
    }

    private func prepareNative(profile: RecordingFeedbackProfile) async throws -> LinuxRecordingFeedbackOutput {
        try Task.checkCancellation()
        let start = try RecordingFeedbackResources.url(for: .start, profile: profile)
        let stop = try RecordingFeedbackResources.url(for: .stop, profile: profile)
        let output = try LinuxRecordingFeedbackOutput()
        return try await withTaskCancellationHandler {
            do {
                try await Task.detached { try output.prepare(start: start, stop: stop) }.value
                try Task.checkCancellation()
                return output
            } catch {
                await output.close()
                throw error
            }
        } onCancel: {
            output.cancelPreparation()
        }
    }
}

private final class LinuxFeedbackFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String) -> Void)?
    private var pending: String?

    func publish(_ message: String) {
        let callback = lock.withLock {
            if handler == nil { pending = message }
            return handler
        }
        callback?(message)
    }

    func setHandler(_ handler: @escaping @Sendable (String) -> Void) {
        let message = lock.withLock {
            self.handler = handler
            defer { pending = nil }
            return pending
        }
        if let message { handler(message) }
    }
}

private final class LinuxRecordingFeedbackOutput: DesktopRecordingFeedbackOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let failure = LinuxFeedbackFailure()
    private var handle: OpaquePointer?

    init() throws {
        let context = Unmanaged.passUnretained(failure).toOpaque()
        handle = jsti_recording_feedback_create({ message, context in
            guard let message, let context else { return }
            Unmanaged<LinuxFeedbackFailure>.fromOpaque(context).takeUnretainedValue().publish(String(cString: message))
        }, context)
        guard handle != nil else { throw LinuxFeedbackError(message: "Recording sound state could not be allocated.") }
    }

    deinit {
        if let handle { jsti_recording_feedback_destroy(handle) }
    }

    // The detached preparation worker retains this object until the native call returns.
    // The loader does not expose it or close it before that join.
    func prepare(start: URL, stop: URL) throws {
        guard let handle = lock.withLock({ self.handle }) else { throw CancellationError() }
        var error = [CChar](repeating: 0, count: 512)
        let result = jsti_recording_feedback_prepare(handle, start.path, stop.path, &error, error.count)
        if result == 1 { throw CancellationError() }
        guard result == 0 else { throw LinuxFeedbackError(message: String(cString: error)) }
    }

    func cancelPreparation() {
        lock.withLock {
            if let handle { jsti_recording_feedback_cancel_preparation(handle) }
        }
    }

    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        failure.setHandler(handler)
    }

    func play(_ sound: RecordingFeedbackSound, gain: Float) throws {
        try lock.withLock {
            guard let handle else { throw LinuxFeedbackError(message: "Recording sound output is closed.") }
            var error = [CChar](repeating: 0, count: 512)
            guard jsti_recording_feedback_play(handle, sound == .start ? 0 : 1, gain, &error, error.count) == 0 else {
                throw LinuxFeedbackError(message: String(cString: error))
            }
        }
    }

    func stop() {
        lock.withLock {
            if let handle { jsti_recording_feedback_stop(handle) }
        }
    }

    func queuedLatency() -> Double {
        lock.withLock { handle.map { jsti_recording_feedback_queued_latency($0) } ?? -1 }
    }

    func close() async {
        await Task.detached {
            self.lock.withLock {
                guard let handle = self.handle else { return }
                self.handle = nil
                jsti_recording_feedback_destroy(handle)
            }
        }.value
    }
}

private struct LinuxFeedbackError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
