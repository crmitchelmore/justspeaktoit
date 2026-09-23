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

    private final class Run: @unchecked Sendable {
        let id = UUID()
        let recordID: UUID
        let path: String
        let knownDuration: TimeInterval?
        let worker = DispatchQueue(label: "JustSpeakToIt.playback.job", qos: .utility)
        // All fields below are protected by the controller lock. Only the job
        // worker invokes the handle, including destruction and cheap commands.
        var handle: (any WindowsAudioPlaybackHandle)?
        var sampler: DispatchSourceTimer?
        var display: WindowsAudioPlaybackDisplay
        var startReserved = false
        var stopped = false
        var outputQuiet = false
        var pauseRequested = false
        var pauseCommandQueued = false
        var releaseStarted = false
        var releaseError: String?
        var terminal: WindowsAudioPlaybackCompletion?
        /// An awaiting caller reports its own outcome, so no terminal status is shown.
        var awaiting: ((Result<TimeInterval, Error>) -> Void)?

        init(recordID: UUID, path: String, duration: TimeInterval?) {
            self.recordID = recordID
            self.path = path
            self.knownDuration = duration
            self.display = WindowsAudioPlaybackDisplay(
                recordID: recordID, state: .preparing,
                text: WindowsAudioPlaybackDisplay.text(position: 0, duration: duration)
            )
        }
    }

    private let lock = NSLock()
    private let backend: any WindowsAudioPlaybackBackend
    private let progressInterval: TimeInterval
    private let stopTimeout: TimeInterval
    private let presentations = DispatchQueue(label: "JustSpeakToIt.playback.presentation")
    private var presenter: WindowsAudioPlaybackPresenter
    private var current: Run?
    private var live: [UUID: Run] = [:]
    private var closed = false
    private var revision: UInt64 = 0
    private struct Presentation {
        let display: WindowsAudioPlaybackDisplay
        let status: String?
        let presenter: WindowsAudioPlaybackPresenter
    }
    private var pendingPresentation: Presentation?
    private var deliveryScheduled = false

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

    public var activity: Activity? {
        lock.withLock { current.map { Activity(recordID: $0.recordID, state: $0.display.state) } }
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
    func admit(
        recordID: UUID, path: String, knownDuration: TimeInterval?,
        awaiting: ((Result<TimeInterval, Error>) -> Void)?, claim: ((UUID) -> Bool)? = nil
    ) throws -> UUID {
        try lock.withLock {
            guard !closed else { throw WindowsAudioPlaybackError("The app is closing.") }
            guard live.count < 2 else {
                throw WindowsAudioPlaybackError("Previous playback is still closing. Try again shortly.")
            }
            let run = Run(recordID: recordID, path: path, duration: knownDuration)
            guard claim?(run.id) ?? true else { throw CancellationError() }
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

    @discardableResult
    public func togglePause(recordID: UUID) -> Bool {
        lock.withLock {
            guard let run = current, run.recordID == recordID, !run.stopped else { return false }
            run.pauseRequested.toggle()
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

    /// Requests cancellation. The display resets only after output is quiet.
    /// Call stopAndWait before starting a microphone or another audio owner.
    public func stop() {
        lock.withLock {
            for run in live.values where !run.stopped { stopLocked(run) }
        }
    }

    public func stop(unless recordID: UUID) {
        lock.withLock {
            if let run = current, run.recordID != recordID { stopLocked(run) }
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

    private func stopLocked(_ run: Run) {
        guard !run.stopped else { return }
        run.stopped = true
        // Reserving start and observing cancellation use the same lock. If
        // open is still blocked, cancellation forbids every future start.
        if !run.startReserved { run.outputQuiet = true }
        run.worker.async { self.release(run) }
    }

}

private extension WindowsAudioPlaybackController {
    private func openAndStart(_ run: Run, after previous: Run?) {
        do {
            let handle = try backend.open(path: run.path) { [weak self, weak run] completion in
                guard let self, let run else { return }
                // Queued behind open/start: completion never joins its caller.
                run.worker.async { self.completed(run, completion) }
            }
            lock.withLock { run.handle = handle }
            if let previous { try waitForOutput(previous) }
            let start = lock.withLock { () -> Bool in
                guard !closed, !run.stopped else { run.outputQuiet = true; return false }
                run.startReserved = true
                return true
            }
            guard start else { release(run); return }
            try handle.start()
            if lock.withLock({ run.stopped }) { release(run); return }
            applyPause(run)
            installSampler(run)
        } catch {
            completed(run, WindowsAudioPlaybackCompletion(status: .failed(error.localizedDescription), played: 0))
        }
    }

    private func waitForOutput(_ previous: Run) throws {
        let deadline = ContinuousClock.now + .seconds(stopTimeout)
        while !lock.withLock({ previous.outputQuiet }) {
            guard ContinuousClock.now < deadline else {
                throw WindowsAudioPlaybackError("Previous audio output has not stopped. Playback has not started.")
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    private func applyPause(_ run: Run) {
        let value = lock.withLock { () -> ((any WindowsAudioPlaybackHandle), Bool)? in
            guard !run.stopped, run.startReserved, !run.releaseStarted, let handle = run.handle else { return nil }
            return (handle, run.pauseRequested)
        }
        guard let (handle, pause) = value else { return }
        let state = handle.snapshot().state
        if pause, state != .paused { handle.pause() } else if !pause, state == .paused { handle.resume() }
    }

    private func installSampler(_ run: Run) {
        let timer = DispatchSource.makeTimerSource(queue: run.worker)
        timer.schedule(deadline: .now() + progressInterval, repeating: progressInterval)
        timer.setEventHandler { [weak self, weak run] in
            if let self, let run { self.sample(run) }
        }
        lock.withLock { run.sampler = timer }
        timer.resume()
    }

    private func sample(_ run: Run) {
        let handle = lock.withLock { !run.stopped && current === run ? run.handle : nil }
        guard let handle else { return }
        let snapshot = handle.snapshot()
        guard snapshot.state != .ended else { return }
        let state: WindowsAudioPlaybackDisplay.State
        switch snapshot.state {
        case .preparing: state = .preparing
        case .playing: state = .playing
        case .paused: state = .paused
        case .ended: return
        }
        let display = WindowsAudioPlaybackDisplay(
            recordID: run.recordID, state: state,
            text: WindowsAudioPlaybackDisplay.text(
                position: snapshot.position, duration: snapshot.duration ?? run.knownDuration
            )
        )
        lock.withLock {
            guard current === run, !run.stopped, display != run.display else { return }
            run.display = display
            publishLocked(display)
        }
    }

    private func completed(_ run: Run, _ completion: WindowsAudioPlaybackCompletion) {
        lock.withLock {
            guard live[run.id] != nil, run.terminal == nil else { return }
            run.terminal = completion
            run.stopped = true
        }
        release(run)
    }

    private struct Release { let handle: (any WindowsAudioPlaybackHandle)? }
    private func release(_ run: Run) {
        let claim = lock.withLock { () -> Release? in
            guard live[run.id] != nil, !run.releaseStarted else { return nil }
            run.releaseStarted = true
            run.sampler?.cancel()
            run.sampler = nil
            return Release(handle: run.handle)
        }
        guard let claim else { return }
        let owned = claim.handle
        var acknowledgedRevision: UInt64?
        // A failed open owns no handle. Open is the first command on its
        // serial worker, so nil here never races a future handle publication.
        do {
            if let owned { try silence(owned) }
            lock.withLock {
                run.outputQuiet = true
                if current === run {
                    current = nil
                    let display = WindowsAudioPlaybackDisplay(
                        recordID: run.recordID, state: .idle,
                        text: WindowsAudioPlaybackDisplay.text(position: 0, duration: run.knownDuration)
                    )
                    publishLocked(display, status: run.awaiting == nil ? Self.terminalMessage(run.terminal) : nil)
                    acknowledgedRevision = revision
                }
            }
            try owned?.destroy()
            takeAwaiting(run, released: true)?(Self.outcome(run.terminal))
        } catch {
            takeAwaiting(run, released: false)?(.failure(error))
            lock.withLock {
                run.releaseError = error.localizedDescription
                if current === run || revision == acknowledgedRevision {
                    let display = WindowsAudioPlaybackDisplay(
                        recordID: run.recordID, state: run.outputQuiet ? .idle : run.display.state,
                        text: run.display.text
                    )
                    publishLocked(display, status: "Playback could not close: \(error.localizedDescription)")
                }
            }
        }
    }

    private func silence(_ owned: any WindowsAudioPlaybackHandle) throws {
        owned.cancel()
        let deadline = ContinuousClock.now + .seconds(stopTimeout)
        while !owned.snapshot().outputIsQuiet {
            guard ContinuousClock.now < deadline else {
                throw WindowsAudioPlaybackError("Audio output did not acknowledge stopping.")
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    /// Taken once, so an awaiting caller resumes exactly once, outside the lock.
    private func takeAwaiting(_ run: Run, released: Bool) -> ((Result<TimeInterval, Error>) -> Void)? {
        lock.withLock {
            if released {
                run.handle = nil
                live[run.id] = nil
            }
            defer { run.awaiting = nil }
            return run.awaiting
        }
    }

    /// Enqueue while holding the state lock, deliver outside it on one serial
    /// queue. A blocked or reentrant callback cannot let a later publication
    /// overtake it, even when both generations refer to the same History row.
    private func publishLocked(_ display: WindowsAudioPlaybackDisplay, status: String? = nil) {
        revision &+= 1
        let version = revision
        let display = WindowsAudioPlaybackDisplay(
            recordID: display.recordID, state: display.state, text: display.text, revision: version
        )
        pendingPresentation = Presentation(display: display, status: status, presenter: presenter)
        guard !deliveryScheduled else { return }
        deliveryScheduled = true
        presentations.async { self.deliverPresentations() }
    }

    private func deliverPresentations() {
        while true {
            let next = lock.withLock { () -> Presentation? in
                guard !closed, let next = pendingPresentation else {
                    pendingPresentation = nil
                    deliveryScheduled = false
                    return nil
                }
                pendingPresentation = nil
                return next
            }
            guard let next else { return }
            next.presenter.show(next.display)
            if let status = next.status, lock.withLock({ revision == next.display.revision && !closed }) {
                next.presenter.status(WindowsAudioPlaybackStatus(revision: next.display.revision, message: status))
            }
        }
    }
}
