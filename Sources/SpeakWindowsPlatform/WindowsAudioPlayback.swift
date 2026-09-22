import Foundation
import CWindowsSupport

/// Native in-process playback of a local audio file through the default
/// Windows output device. The original encoded file stays pinned read-only
/// and is decoded by the installed Media Foundation codecs to the endpoint's
/// shared-mode mix format, then rendered through event-driven WASAPI on
/// dedicated native threads. No external player, web view or transcription
/// conversion is involved.
public enum WindowsAudioPlayback {
    public struct Output: Equatable, Sendable {
        /// Source audio the audio engine actually consumed, in seconds.
        public let playedDuration: TimeInterval

        public init(playedDuration: TimeInterval) { self.playedDuration = playedDuration }
    }

    /// Largest accepted input; two hours of 24 kHz PCM16 history is about 346 MB.
    public static let maximumInputBytes: UInt64 = 1 << 30

    /// Plays the whole file and honours task cancellation. Returning waits for
    /// native destruction, so the caller may remove or replace the file after
    /// this function returns or throws.
    public static func play(
        input: URL, backend: any WindowsAudioPlaybackBackend = WindowsAudioPlaybackNativeBackend()
    ) async throws -> Output {
        guard input.isFileURL, !input.path.utf8.contains(0) else {
            throw WindowsAudioPlaybackError("Choose a local audio file to play.")
        }
        let operation = AudioPlaybackOperation(path: input.path, backend: backend)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { operation.start($0) }
        } onCancel: { operation.cancel() }
    }

    /// Precise capability probe: true when Windows reports an active default
    /// multimedia output endpoint. Throws when Windows could not answer. It
    /// never infers availability from a playback failure, and a true result
    /// does not promise that a later playback succeeds.
    public static func isOutputEndpointAvailable() throws -> Bool {
        var error = [CChar](repeating: 0, count: 1_024)
        switch jsti_audio_playback_endpoint_available(&error, error.count) {
        case 1: return true
        case 0: return false
        default: throw WindowsAudioPlaybackError(String(cString: error))
        }
    }
}

public struct WindowsAudioPlaybackError: LocalizedError, Equatable, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

/// Native snapshot state; `ended` details arrive through the completion.
public enum WindowsAudioPlaybackState: Int32, Equatable, Sendable {
    case preparing = 0
    case playing = 1
    case paused = 2
    case ended = 3
}

public struct WindowsAudioPlaybackSnapshot: Equatable, Sendable {
    public let state: WindowsAudioPlaybackState
    /// Source audio actually consumed by the engine so far; stable while paused.
    public let position: TimeInterval
    /// Container duration when the source reports one.
    public let duration: TimeInterval?

    public init(state: WindowsAudioPlaybackState, position: TimeInterval, duration: TimeInterval?) {
        self.state = state
        self.position = position
        self.duration = duration
    }

    init(native: JSTIAudioPlaybackSnapshot) {
        self.init(
            state: WindowsAudioPlaybackState(rawValue: native.state) ?? .ended,
            position: native.position_seconds.isFinite && native.position_seconds >= 0 ? native.position_seconds : 0,
            duration: native.duration_seconds.isFinite && native.duration_seconds >= 0 ? native.duration_seconds : nil
        )
    }
}

/// The exactly-once terminal outcome of one native playback.
public struct WindowsAudioPlaybackCompletion: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case finished
        case cancelled
        case failed(String)
    }

    public let status: Status
    /// Source audio the engine consumed before playback ended.
    public let played: TimeInterval

    public init(status: Status, played: TimeInterval) {
        self.status = status
        self.played = played
    }
}

/// One native playback job. Every method except `destroy` is nonblocking and
/// thread safe. `destroy` cancels, joins both native threads and frees the
/// job; call it off the completion thread and off UI/actor threads, only
/// after `start` has returned, and never twice concurrently.
public protocol WindowsAudioPlaybackHandle: AnyObject, Sendable {
    func start() throws
    func pause()
    func resume()
    func cancel()
    func snapshot() -> WindowsAudioPlaybackSnapshot
    func destroy() throws
}

/// Seam between the playback controller and the native engine, so the
/// controller's ownership rules are testable without a speaker.
public protocol WindowsAudioPlaybackBackend: Sendable {
    /// Pins the file without touching any device. The completion runs exactly
    /// once on a native thread after a successful `start`, possibly before
    /// `start` returns; it must not destroy the handle.
    func open(
        path: String, completion: @escaping @Sendable (WindowsAudioPlaybackCompletion) -> Void
    ) throws -> any WindowsAudioPlaybackHandle
}

public struct WindowsAudioPlaybackNativeBackend: WindowsAudioPlaybackBackend {
    public init() {}

    public func open(
        path: String, completion: @escaping @Sendable (WindowsAudioPlaybackCompletion) -> Void
    ) throws -> any WindowsAudioPlaybackHandle {
        try NativePlaybackHandle(path: path, completion: completion)
    }
}

/// Retained by the native job until destroy has joined, so no C callback can
/// reach freed memory.
private final class NativePlaybackContext {
    let completion: @Sendable (WindowsAudioPlaybackCompletion) -> Void
    init(_ completion: @escaping @Sendable (WindowsAudioPlaybackCompletion) -> Void) { self.completion = completion }
}

private final class NativePlaybackHandle: WindowsAudioPlaybackHandle, @unchecked Sendable {
    private let lock = NSLock()
    private var native: OpaquePointer?
    private var context: UnsafeMutableRawPointer?

    init(path: String, completion: @escaping @Sendable (WindowsAudioPlaybackCompletion) -> Void) throws {
        guard !path.utf8.contains(0) else { throw WindowsAudioPlaybackError("Choose a local audio file to play.") }
        let retained = Unmanaged.passRetained(NativePlaybackContext(completion)).toOpaque()
        var error = [CChar](repeating: 0, count: 1_024)
        let created = path.withCString {
            jsti_audio_playback_create($0, audioPlaybackCompleted, retained, &error, error.count)
        }
        guard let created else {
            Unmanaged<NativePlaybackContext>.fromOpaque(retained).release()
            throw WindowsAudioPlaybackError(String(cString: error))
        }
        native = created
        context = retained
    }

    deinit {
        // Owners always destroy explicitly; this only prevents a leaked worker
        // when a handle is dropped, and keeps the context if native refuses.
        if let native, jsti_audio_playback_destroy(native, nil, 0) == 0, let context {
            Unmanaged<NativePlaybackContext>.fromOpaque(context).release()
        }
    }

    // Quick calls hold the lock while native runs, and destroy takes ownership
    // under the same lock before joining, so no call can outlive the job.
    func start() throws {
        var error = [CChar](repeating: 0, count: 1_024)
        let status: Int32 = lock.withLock {
            guard let native else { return -1 }
            return jsti_audio_playback_start(native, &error, error.count)
        }
        guard status == 0 else {
            let message = String(cString: error)
            throw WindowsAudioPlaybackError(message.isEmpty ? "Playback was already released." : message)
        }
    }

    func pause() { lock.withLock { if let native { _ = jsti_audio_playback_pause(native) } } }

    func resume() { lock.withLock { if let native { _ = jsti_audio_playback_resume(native) } } }

    func cancel() { lock.withLock { if let native { jsti_audio_playback_cancel(native) } } }

    func snapshot() -> WindowsAudioPlaybackSnapshot {
        lock.withLock {
            var value = JSTIAudioPlaybackSnapshot()
            guard let native, jsti_audio_playback_snapshot(native, &value) == 0 else {
                return WindowsAudioPlaybackSnapshot(state: .ended, position: 0, duration: nil)
            }
            return WindowsAudioPlaybackSnapshot(native: value)
        }
    }

    func destroy() throws {
        let owned = lock.withLock { () -> (OpaquePointer?, UnsafeMutableRawPointer?) in
            let owned = (native, context)
            native = nil
            context = nil
            return owned
        }
        guard let handle = owned.0 else { return }
        var error = [CChar](repeating: 0, count: 1_024)
        guard jsti_audio_playback_destroy(handle, &error, error.count) == 0 else {
            // Native ownership stays alive on failure: keep the job and its
            // context reachable so a retry can succeed and no callback can
            // touch freed memory.
            lock.withLock {
                native = handle
                context = owned.1
            }
            throw WindowsAudioPlaybackError(String(cString: error))
        }
        if let context = owned.1 { Unmanaged<NativePlaybackContext>.fromOpaque(context).release() }
    }
}

private func audioPlaybackCompleted(
    _ status: Int32, _ played: Double, _ error: UnsafePointer<CChar>?, _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let box = Unmanaged<NativePlaybackContext>.fromOpaque(context).takeUnretainedValue()
    let playedSeconds = played.isFinite && played >= 0 ? played : 0
    let completion: WindowsAudioPlaybackCompletion
    switch status {
    case 0: completion = WindowsAudioPlaybackCompletion(status: .finished, played: playedSeconds)
    case 1: completion = WindowsAudioPlaybackCompletion(status: .cancelled, played: playedSeconds)
    default:
        let message = error.map(String.init(cString:)) ?? ""
        let reason = message.isEmpty ? "Windows could not play this audio file." : message
        completion = WindowsAudioPlaybackCompletion(status: .failed(reason), played: playedSeconds)
    }
    box.completion(completion)
}

/// One-shot playback for `WindowsAudioPlayback.play`. Mirrors the conversion
/// bridge: the native completion runs on the worker being joined, so
/// destruction always happens on another queue and the continuation resumes
/// only after that join.
private final class AudioPlaybackOperation: @unchecked Sendable {
    private let path: String
    private let backend: any WindowsAudioPlaybackBackend
    private let lock = NSLock()
    private var handle: (any WindowsAudioPlaybackHandle)?
    private var continuation: CheckedContinuation<WindowsAudioPlayback.Output, Error>?
    private var cancelled = false
    private var completing = false

    init(path: String, backend: any WindowsAudioPlaybackBackend) {
        self.path = path
        self.backend = backend
    }

    func start(_ continuation: CheckedContinuation<WindowsAudioPlayback.Output, Error>) {
        var failure: Error?
        let opened: (any WindowsAudioPlaybackHandle)? = lock.withLock {
            self.continuation = continuation
            guard !cancelled else { failure = CancellationError(); return nil }
            do {
                let opened = try backend.open(path: path) { [weak self] completion in
                    self?.complete(completion)
                }
                handle = opened
                return opened
            } catch {
                failure = error
                return nil
            }
        }
        // Start outside the lock: a completion may arrive before start returns.
        if let opened {
            do { try opened.start() } catch { failure = error }
        }
        if let failure { complete(.failure(failure)) }
    }

    func cancel() {
        let owned: (any WindowsAudioPlaybackHandle)? = lock.withLock {
            cancelled = true
            return handle
        }
        owned?.cancel()
    }

    private func complete(_ completion: WindowsAudioPlaybackCompletion) {
        switch completion.status {
        case .finished: complete(.success(WindowsAudioPlayback.Output(playedDuration: completion.played)))
        case .cancelled: complete(.failure(CancellationError()))
        case .failed(let message): complete(.failure(WindowsAudioPlaybackError(message)))
        }
    }

    private func complete(_ result: Result<WindowsAudioPlayback.Output, Error>) {
        let shouldFinish: Bool = lock.withLock {
            guard !completing else { return false }
            completing = true
            return true
        }
        guard shouldFinish else { return }
        DispatchQueue.global(qos: .utility).async { self.finish(result) }
    }

    private func finish(_ result: Result<WindowsAudioPlayback.Output, Error>) {
        let owned: (any WindowsAudioPlaybackHandle)? = lock.withLock {
            let owned = handle
            handle = nil
            return owned
        }
        var finalResult = result
        if let owned {
            do { try owned.destroy() } catch { finalResult = .failure(error) }
        }
        let completion: CheckedContinuation<WindowsAudioPlayback.Output, Error>? = lock.withLock {
            if cancelled, case .failure = finalResult { finalResult = .failure(CancellationError()) }
            let completion = continuation
            continuation = nil
            return completion
        }
        completion?.resume(with: finalResult)
    }
}
