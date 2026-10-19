import Foundation

/// One immutable recording's latest-wins text lane. Never called from the PCM
/// path. Cancellation retires identity before cancelling non-cooperative clients.
public final class LivePolishSession: @unchecked Sendable {
    public typealias Complete = @Sendable (_ text: String) async throws -> String
    public typealias Sleep = @Sendable (_ duration: Duration) async throws -> Void

    public struct Result: Codable, Equatable, Sendable {
        public let input: String
        public let text: String?
        public let modelIdentifier: String
        public let failure: String?
        public var succeeded: Bool { text != nil && failure == nil }
    }

    public let recordingID: UUID
    public let preferences: LivePolishPreferences
    public let modelIdentifier: String
    private let complete: Complete
    private let sleep: Sleep
    private let onChange: @Sendable (Result) -> Void
    private let lock = NSLock()
    private var input = ""
    private var lastRequested = ""
    private var successful: Result?
    private var failure: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var timeout: Task<Void, Never>?
    private var finishing = false
    private var paused = false
    private var retired = false
    private var waiters: [CheckedContinuation<Result, Never>] = []

    private enum DeliverySource {
        case worker
        case timeout
    }

    public init(
        recordingID: UUID, preferences: LivePolishPreferences, modelIdentifier: String,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        onChange: @escaping @Sendable (Result) -> Void = { _ in },
        complete: @escaping Complete
    ) {
        self.recordingID = recordingID
        self.preferences = preferences
        self.modelIdentifier = modelIdentifier
        self.sleep = sleep
        self.onChange = onChange
        self.complete = complete
    }

    public func snapshot() -> Result { lock.withLock { current() } }

    public func submit(_ text: String) {
        submit(text, immediately: false)
    }

    public func submit(_ text: String, immediately: Bool) {
        let old = lock.withLock { () -> [Task<Void, Never>] in
            guard preferences.mode == .livePolish, !retired, !finishing, !paused,
                  text != input || immediately else { return [] }
            let old = tasks()
            let replacement = text != input && !text.hasPrefix(input)
            generation = UUID()
            input = text
            failure = nil
            task = nil
            timeout = nil
            if successful?.input == text { return old }
            if (immediately || replacement) && !TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(text)
                || LivePolishPolicy.shouldRequest(
                text, after: lastRequested, minimumDelta: preferences.minimumDeltaCharacters
            ) { launch(delay: immediately ? .zero : .milliseconds(preferences.debounceMilliseconds)) }
            return old
        }
        old.forEach { $0.cancel() }
    }

    /// Stop partial requests at capture stop, retaining only an exact-input cache.
    public func pause() {
        let old = lock.withLock { () -> [Task<Void, Never>] in
            guard !finishing else { return [] }
            let old = tasks()
            paused = true
            generation = UUID()
            task = nil
            timeout = nil
            return old
        }
        old.forEach { $0.cancel() }
    }

    /// The corrected authoritative final, never an older preview. Multiple
    /// finish callers share one request; cancellation/timeout always wakes them.
    public func finish(_ text: String) async -> Result {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let action = lock.withLock { () -> ([Task<Void, Never>], Result?) in
                    if retired { return ([], current()) }
                    if finishing {
                        waiters.append(continuation)
                        return ([], nil)
                    }
                    let old = tasks()
                    generation = UUID()
                    task = nil
                    timeout = nil
                    input = text
                    failure = nil
                    finishing = true
                    if preferences.mode == .instant
                        || TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(text)
                        || successful?.input == text {
                        retired = true
                        return (old, current())
                    }
                    waiters.append(continuation)
                    launch(delay: .zero)
                    return (old, nil)
                }
                action.0.forEach { $0.cancel() }
                if let result = action.1 { continuation.resume(returning: result) }
            }
        } onCancel: { self.cancel() }
    }

    public func cancel() {
        settleRetirement(message: LivePolishError.cancelled.localizedDescription)
    }

    private func settleRetirement(message: String) {
        // existing owned lock-scoped retirement state; no behavior change.
        // swiftlint:disable:next large_tuple
        let action = lock.withLock { () -> ([Task<Void, Never>], [CheckedContinuation<Result, Never>], Result) in
            let old = tasks()
            generation = UUID()
            retired = true
            failure = message
            task = nil
            timeout = nil
            let pending = waiters
            waiters = []
            return (old, pending, current())
        }
        action.0.forEach { $0.cancel() }
        onChange(action.2)
        action.1.forEach { $0.resume(returning: action.2) }
    }

    // Called under lock; workers cannot enter admission until the lock is released.
    private func launch(delay: Duration) {
        let token = generation
        let text = input
        let sleep = sleep
        let complete = complete
        let preferences = preferences
        task = Task { [weak self] in
            do {
                guard (0...60_000).contains(preferences.debounceMilliseconds),
                      (0...65_535).contains(preferences.minimumDeltaCharacters) else {
                    throw LivePolishError.invalidConfiguration
                }
                if delay > .zero { try await sleep(delay) }
                try Task.checkCancellation()
                guard self?.admit(token: token, text: text) == true else { return }
                let output = try await complete(text).trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation()
                guard !output.isEmpty,
                      !TranscriptPostProcessingPolicy.isEffectivelyEmptyTranscript(output) else {
                    throw LivePolishError.invalidResponse
                }
                self?.receive(source: .worker, token: token, text: text, output: output, error: nil)
            } catch {
                self?.receive(
                    source: .worker, token: token, text: text, output: nil,
                    error: error is CancellationError ? LivePolishError.cancelled.localizedDescription
                        : error.localizedDescription
                )
            }
        }
    }

    private func admit(token: UUID, text: String) -> Bool {
        lock.withLock {
            guard !retired, token == generation, input == text else { return false }
            lastRequested = text
            let sleep = sleep
            timeout = Task { [weak self] in
                do { try await sleep(LivePolishPolicy.requestTimeout) } catch { return }
                self?.receive(
                    source: .timeout, token: token, text: text, output: nil,
                    error: LivePolishError.timedOut.localizedDescription
                )
            }
            return true
        }
    }

    private func receive(source: DeliverySource, token: UUID, text: String, output: String?, error: String?) {
        let action = lock.withLock {
            // swiftlint:disable:next large_tuple
            () -> (Task<Void, Never>?, [CheckedContinuation<Result, Never>], Result)? in
            guard !retired, token == generation, input == text else { return nil }
            // The producer is already finishing; only its peer needs cancellation.
            let peer: Task<Void, Never>?
            switch source {
            case .worker: peer = timeout
            case .timeout: peer = task
            }
            generation = UUID()
            task = nil
            timeout = nil
            failure = error
            if let output {
                successful = Result(input: text, text: output, modelIdentifier: modelIdentifier, failure: nil)
            }
            if finishing { retired = true }
            let pending = waiters
            waiters = []
            return (peer, pending, current())
        }
        guard let action else { return }
        action.0?.cancel()
        onChange(action.2)
        action.1.forEach { $0.resume(returning: action.2) }
    }

    private func tasks() -> [Task<Void, Never>] { [task, timeout].compactMap { $0 } }

    private func current() -> Result {
        Result(
            input: input, text: failure == nil && successful?.input == input ? successful?.text : nil,
            modelIdentifier: modelIdentifier, failure: failure
        )
    }
}
