import Foundation
import SpeakCore
import SpeakDesktop
import SpeakFeedbackResources
import CWindowsSupport

private func feedbackErrorMessage(_ buffer: [CChar]) -> String {
    String(bytes: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8)
        ?? "Recording feedback returned an invalid UTF-8 error."
}

public struct WindowsRecordingFeedbackError: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Bundled M4As are decoded once on an owned native worker. The returned
/// channel retains PCM and its independent 30 ms WASAPI renderer until close.
public struct WindowsRecordingFeedbackLoader: DesktopRecordingFeedbackLoader {
    public init() {}

    /// Decodes both bundled AAC cues without opening an audio endpoint.
    public static func checkAssets(profile: RecordingFeedbackProfile) async throws -> Int {
        try await Task.detached {
            let start = try RecordingFeedbackResources.url(for: .start, profile: profile)
            let stop = try RecordingFeedbackResources.url(for: .stop, profile: profile)
            var error = [CChar](repeating: 0, count: 1_024)
            let count = jsti_recording_feedback_check_assets(start.path, stop.path, &error, error.count)
            guard count == 2 else { throw WindowsRecordingFeedbackError(feedbackErrorMessage(error)) }
            return Int(count)
        }.value
    }

    /// Uses a real dedicated WASAPI endpoint. Returns start/stop first-buffer
    /// queue latencies in seconds (each <= 100 ms), not audible latency.
    public static func checkNativeOutput(profile: RecordingFeedbackProfile) async throws -> [Double] {
        let output = try await prepareNative(profile: profile)
        return try await withTaskCancellationHandler {
            var latencies: [Double] = []
            do {
                for sound in [RecordingFeedbackSound.start, .stop] {
                    latencies.append(try await output.measureQueueLatency(sound: sound))
                    output.stop()
                    try await output.awaitStop()
                }
            } catch {
                do {
                    try await output.close()
                } catch let cleanup {
                    throw WindowsRecordingFeedbackError(
                        "\(error.localizedDescription) Cleanup: \(cleanup.localizedDescription)"
                    )
                }
                throw error
            }
            try await output.close()
            try output.checkDiagnosticFailure()
            try Task.checkCancellation()
            return latencies
        } onCancel: {
            output.stop()
        }
    }

    public func prepare(profile: RecordingFeedbackProfile) async throws -> any DesktopRecordingFeedbackOutput {
        try await Self.prepareNative(profile: profile)
    }

    private static func prepareNative(
        profile: RecordingFeedbackProfile
    ) async throws -> WindowsRecordingFeedbackOutput {
        let output = WindowsRecordingFeedbackOutput()
        return try await withTaskCancellationHandler {
            let prepared = try await Task.detached {
                do {
                    try Task.checkCancellation()
                    let start = try RecordingFeedbackResources.url(for: .start, profile: profile)
                    let stop = try RecordingFeedbackResources.url(for: .stop, profile: profile)
                    try output.prepare(start: start, stop: stop)
                    return output
                } catch {
                    do {
                        try output.destroy()
                    } catch let cleanup {
                        throw WindowsRecordingFeedbackError(
                            "\(error.localizedDescription) Cleanup: \(cleanup.localizedDescription)"
                        )
                    }
                    throw error
                }
            }.value
            if Task.isCancelled {
                try await prepared.close()
                throw CancellationError()
            }
            return prepared
        } onCancel: {
            output.cancelPreparation()
        }
    }
}

// Separate callback context, not the output itself: destruction can join a
// callback without reviving an object whose deinit has already begun.
private final class FeedbackFailureRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String) -> Void)?
    private var pending: [String] = []
    private var latest: String?

    var lastFailure: String? { lock.withLock { latest } }

    func install(_ handler: @escaping @Sendable (String) -> Void) {
        let messages = lock.withLock {
            self.handler = handler
            let messages = pending
            pending.removeAll()
            return messages
        }
        for message in messages { handler(message) }
    }

    func publish(_ message: String) {
        let callback = lock.withLock {
            latest = message
            if handler == nil { pending.append(message) }
            return handler
        }
        callback?(message)
    }
}

private final class WindowsRecordingFeedbackOutput: DesktopRecordingFeedbackOutput, @unchecked Sendable {
    private let lock = NSLock()
    private let relay = FeedbackFailureRelay()
    private var native: OpaquePointer?
    private var cancelled = false
    private var closed = false
    private let destruction = NSCondition()
    private var destroying = false
    private var destroyed = false
    private var destructionError: String?

    func setFailureHandler(_ handler: @escaping @Sendable (String) -> Void) {
        relay.install(handler)
    }

    func prepare(start: URL, stop: URL) throws {
        guard start.isFileURL, stop.isFileURL,
              !start.path.utf8.contains(0), !stop.path.utf8.contains(0) else {
            throw WindowsRecordingFeedbackError("Recording feedback requires local bundled assets.")
        }
        var error = [CChar](repeating: 0, count: 1_024)
        let handle: OpaquePointer = try lock.withLock {
            if cancelled || closed { throw CancellationError() }
            guard let handle = jsti_recording_feedback_create({ message, context in
                guard let message, let context else { return }
                Unmanaged<FeedbackFailureRelay>.fromOpaque(context).takeUnretainedValue()
                    .publish(String(cString: message))
            }, Unmanaged.passUnretained(relay).toOpaque(), &error, error.count) else {
                throw WindowsRecordingFeedbackError(feedbackErrorMessage(error))
            }
            native = handle
            return handle
        }
        let status = jsti_recording_feedback_prepare(handle, start.path, stop.path, &error, error.count)
        if lock.withLock({ cancelled }) { throw CancellationError() }
        guard status == 0 else { throw WindowsRecordingFeedbackError(feedbackErrorMessage(error)) }
    }

    func cancelPreparation() {
        lock.withLock {
            cancelled = true
            if let native { jsti_recording_feedback_cancel_preparation(native) }
        }
    }

    func play(_ sound: RecordingFeedbackSound, gain: Float) throws {
        try lock.withLock {
            guard let native, !closed, !cancelled else {
                throw WindowsRecordingFeedbackError("Recording feedback channel is closed or cancelled.")
            }
            var error = [CChar](repeating: 0, count: 1_024)
            guard jsti_recording_feedback_play(native, sound == .start ? 0 : 1, gain, &error, error.count) == 0 else {
                throw WindowsRecordingFeedbackError(feedbackErrorMessage(error))
            }
        }
    }

    func stop() {
        lock.withLock {
            if let native { jsti_recording_feedback_stop(native) }
        }
    }

    func firstBufferLatency() throws -> Double {
        try lock.withLock {
            guard let native else { throw WindowsRecordingFeedbackError("Recording feedback channel is closed.") }
            var error = [CChar](repeating: 0, count: 1_024)
            let latency = jsti_recording_feedback_first_buffer_latency(native, &error, error.count)
            guard latency >= 0 else { throw WindowsRecordingFeedbackError(feedbackErrorMessage(error)) }
            return latency
        }
    }

    func stopAcknowledged() throws -> Bool {
        try lock.withLock {
            guard let native else { throw WindowsRecordingFeedbackError("Recording feedback channel is closed.") }
            var error = [CChar](repeating: 0, count: 1_024)
            let status = jsti_recording_feedback_stop_acknowledged(native, &error, error.count)
            guard status >= 0 else { throw WindowsRecordingFeedbackError(feedbackErrorMessage(error)) }
            return status == 1
        }
    }

    func checkDiagnosticFailure() throws {
        if let message = relay.lastFailure { throw WindowsRecordingFeedbackError(message) }
    }

    func close() async throws {
        try await Task.detached { try self.destroy() }.value
    }

    func measureQueueLatency(sound: RecordingFeedbackSound) async throws -> Double {
        try Task.checkCancellation()
        try play(sound, gain: 1)
        let deadline = ContinuousClock.now + .milliseconds(100)
        while true {
            try Task.checkCancellation()
            let latency = try firstBufferLatency()
            if latency > 0 {
                guard latency.isFinite, latency <= 0.1 else {
                    throw WindowsRecordingFeedbackError(
                        "Recording feedback \(sound.rawValue) first-buffer queue exceeded 100 ms."
                    )
                }
                return latency
            }
            guard ContinuousClock.now < deadline else {
                throw WindowsRecordingFeedbackError(
                    "Recording feedback \(sound.rawValue) did not queue its first buffer within 100 ms."
                )
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func awaitStop() async throws {
        let deadline = ContinuousClock.now + .milliseconds(250)
        while true {
            try Task.checkCancellation()
            if try stopAcknowledged() { return }
            guard ContinuousClock.now < deadline else {
                throw WindowsRecordingFeedbackError("Recording feedback stop was not acknowledged within 250 ms.")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    func destroy() throws {
        destruction.lock()
        while destroying { destruction.wait() }
        if destroyed {
            let error = destructionError
            destruction.unlock()
            if let error { throw WindowsRecordingFeedbackError(error) }
            return
        }
        destroying = true
        destruction.unlock()
        let handle = lock.withLock {
            closed = true
            let handle = native
            native = nil
            return handle
        }
        var error = [CChar](repeating: 0, count: 1_024)
        let status = withExtendedLifetime(relay) {
            jsti_recording_feedback_destroy(handle, &error, error.count)
        }
        let message = status == 0 ? nil : feedbackErrorMessage(error)
        destruction.lock()
        destructionError = message
        destroying = false
        destroyed = true
        destruction.broadcast()
        destruction.unlock()
        if let message { throw WindowsRecordingFeedbackError(message) }
    }

    deinit {
        if !destruction.withLock({ destroyed }) {
            do {
                try destroy()
            } catch {
                relay.publish(error.localizedDescription)
            }
        }
    }
}

/// Installed-codec and PCM seam check only; it deliberately opens no endpoint.
/// Passes every asset in the shared catalogue, not a duplicated filename list.
public enum WindowsRecordingFeedbackSelfTest {
    public static func validateRenderer() async throws {
        try await Task.detached {
            var error = [CChar](repeating: 0, count: 1_024)
            guard jsti_recording_feedback_renderer_self_test(&error, error.count) == 0 else {
                throw WindowsRecordingFeedbackError(feedbackErrorMessage(error))
            }
        }.value
    }

    public static func validateBundledAssets() async throws {
        try await Task.detached {
            let paths = try RecordingFeedbackProfile.allCases.flatMap { profile in
                try RecordingFeedbackSound.allCases.map {
                    try RecordingFeedbackResources.url(for: $0, profile: profile).path
                }
            }
            let strings = paths.map { Array($0.utf8CString) }
            // Nested buffer scopes keep each UTF-8 pointer alive through C.
            func validate(_ index: Int, _ pointers: [UnsafePointer<CChar>?]) throws {
                if index < strings.count {
                    try strings[index].withUnsafeBufferPointer {
                        try validate(index + 1, pointers + [$0.baseAddress])
                    }
                    return
                }
                var error = [CChar](repeating: 0, count: 1_024)
                let result = pointers.withUnsafeBufferPointer {
                    jsti_recording_feedback_self_test($0.baseAddress, $0.count, &error, error.count)
                }
                guard result == 0 else { throw WindowsRecordingFeedbackError(feedbackErrorMessage(error)) }
            }
            try validate(0, [])
        }.value
    }
}
