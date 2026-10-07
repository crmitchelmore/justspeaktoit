import Foundation

/// Owns at most two jobs, including opens and failed or pending releases.
/// Each job has one serial worker, so open/start/destroy never run on the host
/// actor and a synchronous completion cannot destroy a still-starting handle.
/// Replacement waits for the previous output to be quiet, independently of
/// its decoder flush. A blocked or failed release occupies its bounded slot.
public final class WindowsAudioPlaybackController: @unchecked Sendable {
    public struct Activity: Equatable, Sendable {
        public let recordID: UUID
        public let state: WindowsAudioPlaybackDisplay.State
    }

    // Shared with the job lifecycle in WindowsAudioPlaybackController+Jobs;
    // every mutable field is protected by `lock`.
    let lock = NSLock()
    let backend: any WindowsAudioPlaybackBackend
    let progressInterval: TimeInterval
    let stopTimeout: TimeInterval
    let presentations = DispatchQueue(label: "JustSpeakToIt.playback.presentation")
    var presenter: WindowsAudioPlaybackPresenter
    var current: Run?
    var live: [UUID: Run] = [:]
    var closed = false
    var revision: UInt64 = 0
    var pendingPresentation: Presentation?
    var deliveryScheduled = false
    /// Read aloud in progress; see WindowsAudioPlaybackController+Speech.
    var speechState: SpeechState?

    public init(
        backend: any WindowsAudioPlaybackBackend, presenter: WindowsAudioPlaybackPresenter,
        progressInterval: Duration = .milliseconds(100), stopTimeout: TimeInterval = 3
    ) {
        self.backend = backend
        self.presenter = presenter
        let parts = progressInterval.components
        self.progressInterval = max(0.005, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        self.stopTimeout = max(0.01, stopTimeout)
    }

    public func setPresenter(_ presenter: WindowsAudioPlaybackPresenter) {
        lock.withLock { self.presenter = presenter }
    }

    /// An audible run, else speech between its segments, else a run still stopping.
    public var activity: Activity? {
        lock.withLock {
            if let run = current, !run.stopped || speechState == nil {
                return Activity(recordID: run.recordID, state: run.display.state)
            }
            return speechState.map { Activity(recordID: $0.speech.recordID, state: $0.display.state) }
        }
    }

    public var pendingReleaseCount: Int { lock.withLock { live.count } }

    public func isCurrent(revision: UInt64) -> Bool {
        lock.withLock { self.revision == revision && !closed }
    }

    /// Admits a job without opening a file on the caller's thread. At capacity
    /// it leaves the current playback unchanged and reports a retryable error.
    public func play(recordID: UUID, path: String, knownDuration: TimeInterval?) throws {
        _ = try admit(recordID: recordID, path: path, knownDuration: knownDuration, awaiting: nil)
    }

    /// `claim` runs under the state lock before anything is replaced; refusing
    /// it leaves the current playback untouched and throws `CancellationError`.
    /// A segment of `speech` continues it, and is refused once it has ended;
    /// any other playback ends the speech.
    func admit(
        recordID: UUID, path: String, knownDuration: TimeInterval?,
        awaiting: ((Result<TimeInterval, Error>) -> Void)?, claim: ((UUID) -> Bool)? = nil, speech: Speech? = nil
    ) throws -> UUID {
        try lock.withLock {
            guard !closed else { throw WindowsAudioPlaybackError("The app is closing.") }
            guard live.count < 2 else {
                throw WindowsAudioPlaybackError("Previous playback is still closing. Try again shortly.")
            }
            if let speech, speechState?.speech != speech { throw CancellationError() }
            let run = Run(recordID: recordID, path: path, duration: knownDuration)
            guard claim?(run.id) ?? true else { throw CancellationError() }
            if let state = speechState, speech != nil {
                run.continueSpeech(state)
            } else {
                endSpeechLocked(presenting: false)
            }
            let previous = current
            if let previous { stopLocked(previous) }
            run.awaiting = awaiting
            live[run.id] = run
            current = run
            publishLocked(run.display)
            // Admission and the queued open are atomic relative to close.
            run.worker.async { self.openAndStart(run, after: previous) }
            return run.id
        }
    }

    func stop(runID: UUID) {
        lock.withLock {
            if let run = live[runID], !run.stopped { stopLocked(run) }
        }
    }

    /// Pauses or resumes the record's audible run. Between segments of its
    /// speech, pauses or resumes the speech itself, which its next segment
    /// follows.
    @discardableResult
    public func togglePause(recordID: UUID) -> Bool {
        lock.withLock {
            guard let run = current, run.recordID == recordID, !run.stopped else {
                return toggleSpeechPauseLocked(recordID: recordID)
            }
            run.pauseRequested.toggle()
            if speechState?.speech.recordID == recordID { speechState?.paused = run.pauseRequested }
            if !run.pauseCommandQueued {
                run.pauseCommandQueued = true
                run.worker.async {
                    self.lock.withLock { run.pauseCommandQueued = false }
                    self.applyPause(run)
                }
            }
            return true
        }
    }

    /// Requests cancellation and ends speech. The display resets only after
    /// output is quiet. Call stopAndWait before starting a microphone or
    /// another audio owner. Only the user's Stop is `announcing` and reports
    /// "Playback stopped."; stopping to make way for another row, a search,
    /// recording or import leaves the status line to that work.
    public func stop(announcing: Bool = false) {
        lock.withLock {
            endSpeechLocked()
            for run in live.values where !run.stopped { stopLocked(run, announcing: announcing) }
        }
    }

    /// Stops another record's playback and speech when `recordID` is
    /// selected. The window resets its controls on every row change, so the
    /// selected record's own playback or speech is presented again.
    public func stop(unless recordID: UUID) {
        lock.withLock {
            if let state = speechState, state.speech.recordID != recordID { endSpeechLocked() }
            if let run = current, run.recordID != recordID { stopLocked(run) }
            if let run = current, !run.stopped {
                publishLocked(run.display)
            } else if let state = speechState {
                publishLocked(state.display)
            }
        }
    }

    public func stopAndWait() async throws {
        stop()
        let deadline = ContinuousClock.now + .seconds(stopTimeout)
        while !lock.withLock({ live.values.allSatisfy { $0.outputQuiet } }) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw WindowsAudioPlaybackError("Audio output has not stopped. Recording has not started.")
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Includes already-admitted opens/starts and all release attempts. A failed
    /// destroy remains owned; close reports it instead of claiming successful
    /// release. Calling close again safely retries those bounded failures.
    public func close() async throws {
        lock.withLock {
            closed = true
            speechState = nil
            for run in live.values {
                if run.releaseError != nil {
                    run.releaseError = nil
                    run.releaseStarted = false
                    run.worker.async { self.release(run) }
                } else if !run.stopped { stopLocked(run) }
            }
        }
        while true {
            let outcome: (Bool, String?) = lock.withLock {
                let allAttempted = live.values.allSatisfy { $0.releaseError != nil }
                return (live.isEmpty || allAttempted, live.values.compactMap(\.releaseError).first)
            }
            if outcome.0 {
                await withCheckedContinuation { continuation in
                    presentations.async { continuation.resume() }
                }
                if let error = outcome.1 { throw WindowsAudioPlaybackError(error) }
                return
            }
            // Close owns cleanup even if its caller is cancelled.
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(5)) { continuation.resume() }
            }
        }
    }

    func stopLocked(_ run: Run, announcing: Bool = false) {
        guard !run.stopped else { return }
        run.stopped = true
        run.stopAnnounced = announcing
        // Reserving start and observing cancellation use the same lock. If
        // open is still blocked, cancellation forbids every future start.
        if !run.startReserved { run.outputQuiet = true }
        run.worker.async { self.release(run) }
    }

}
