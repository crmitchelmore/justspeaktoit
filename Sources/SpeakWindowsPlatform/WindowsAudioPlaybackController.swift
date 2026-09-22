import Foundation

/// What the native History pane shows for one record: the acknowledged state
/// and the elapsed/remaining text. Record-bound so a stale update can never
/// describe another row.
public struct WindowsAudioPlaybackDisplay: Equatable, Sendable {
    public enum State: Int32, Equatable, Sendable {
        case idle = 0
        case preparing = 1
        case playing = 2
        case paused = 3
    }

    public let recordID: UUID
    public let state: State
    public let text: String

    public init(recordID: UUID, state: State, text: String) {
        self.recordID = recordID
        self.state = state
        self.text = text
    }

    /// "elapsed / remaining" in the Apple History format. An unknown duration
    /// is shown honestly as "--:--" rather than a guessed remainder.
    public static func text(position: TimeInterval, duration: TimeInterval?) -> String {
        guard let duration, duration.isFinite, duration >= 0 else { return "\(format(position)) / --:--" }
        return "\(format(position)) / \(format(max(duration - position, 0)))"
    }

    static func format(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "--:--.--" }
        let hundredths = Int((time * 100).rounded())
        return String(format: "%02d:%02d.%02d", hundredths / 6_000, (hundredths / 100) % 60, hundredths % 100)
    }
}

/// Host seams for the controller: `show` feeds the native record-bound
/// mailbox and may run on any thread; `status` reports terminal outcomes.
public struct WindowsAudioPlaybackPresenter: Sendable {
    public let show: @Sendable (WindowsAudioPlaybackDisplay) -> Void
    public let status: @Sendable (String) -> Void

    public init(
        show: @escaping @Sendable (WindowsAudioPlaybackDisplay) -> Void,
        status: @escaping @Sendable (String) -> Void
    ) {
        self.show = show
        self.status = status
    }
}

/// Owns at most one audible native playback for the History pane.
///
/// Every control is nonblocking: play pins and starts a job, pause/resume are
/// native commands acknowledged through the sampler, stop cancels audibly at
/// once and moves the join to a background release task. One sampler task per
/// run reads the cheap native snapshot about every 100 ms and presents only
/// changes; nothing is sent from the render thread and no task exists after a
/// run ended. Runs carry a generation identity, so a completion for a replaced
/// run never clears a newer one. Releases are bounded to one per run and are
/// awaited by `close`.
public final class WindowsAudioPlaybackController: @unchecked Sendable {
    public struct Activity: Equatable, Sendable {
        public let recordID: UUID
        public let state: WindowsAudioPlaybackDisplay.State
    }

    private final class Run: @unchecked Sendable {
        let id: UUID
        let recordID: UUID
        let handle: any WindowsAudioPlaybackHandle
        let knownDuration: TimeInterval?
        var sampler: Task<Void, Never>?
        var lastDisplay: WindowsAudioPlaybackDisplay
        var ended = false
        var releaseScheduled = false
        var released = false

        init(id: UUID, recordID: UUID, handle: any WindowsAudioPlaybackHandle, knownDuration: TimeInterval?) {
            self.id = id
            self.recordID = recordID
            self.handle = handle
            self.knownDuration = knownDuration
            self.lastDisplay = WindowsAudioPlaybackDisplay(
                recordID: recordID, state: .preparing,
                text: WindowsAudioPlaybackDisplay.text(position: 0, duration: knownDuration)
            )
        }
    }

    private let lock = NSLock()
    private let backend: any WindowsAudioPlaybackBackend
    private let interval: Duration
    private var presenter: WindowsAudioPlaybackPresenter
    private var current: Run?
    private var live: [UUID: Run] = [:]
    private var releases: [UUID: Task<Void, Never>] = [:]
    private var closed = false

    public init(
        backend: any WindowsAudioPlaybackBackend, presenter: WindowsAudioPlaybackPresenter,
        progressInterval: Duration = .milliseconds(100)
    ) {
        self.backend = backend
        self.presenter = presenter
        self.interval = progressInterval
    }

    public func setPresenter(_ presenter: WindowsAudioPlaybackPresenter) {
        lock.withLock { self.presenter = presenter }
    }

    /// The run that currently owns the output, if any.
    public var activity: Activity? {
        lock.withLock { current.map { Activity(recordID: $0.recordID, state: $0.lastDisplay.state) } }
    }

    /// Runs whose native release has not finished yet; bounded to one per run.
    public var pendingReleaseCount: Int { lock.withLock { live.count } }

    /// Replaces any current playback with a new run for `recordID`. The file
    /// is pinned and the worker started before this returns; the acknowledged
    /// state follows through the presenter.
    public func play(recordID: UUID, path: String, knownDuration: TimeInterval?) throws {
        let retired: Run? = try lock.withLock {
            guard !closed else { throw WindowsAudioPlaybackError("The app is closing.") }
            let old = current
            current = nil
            return old
        }
        if let retired { retire(retired) }
        let runID = UUID()
        let handle = try backend.open(path: path) { [weak self] completion in
            self?.completed(runID: runID, completion)
        }
        let run = Run(id: runID, recordID: recordID, handle: handle, knownDuration: knownDuration)
        let presenter: WindowsAudioPlaybackPresenter = lock.withLock {
            current = run
            live[runID] = run
            return self.presenter
        }
        presenter.show(run.lastDisplay)
        do {
            try handle.start()
        } catch {
            let wasCurrent: Bool = lock.withLock {
                guard current === run else { return false }
                current = nil
                return true
            }
            retire(run)
            if wasCurrent { presenter.show(idleDisplay(for: run)) }
            throw error
        }
        startSampler(run)
    }

    /// Pauses a playing/preparing run or resumes a paused one for `recordID`.
    /// Returns false when no run for that record is active, so the host can
    /// start a new one instead.
    @discardableResult
    public func togglePause(recordID: UUID) -> Bool {
        let run: Run? = lock.withLock {
            guard let current, current.recordID == recordID, !current.ended else { return nil }
            return current
        }
        guard let run else { return false }
        switch run.handle.snapshot().state {
        case .preparing, .playing: run.handle.pause()
        case .paused: run.handle.resume()
        case .ended: break // The completion is about to clear this run.
        }
        return true
    }

    /// Stops the current run: audible output ends now, the display resets to
    /// zero and the native join happens in the background.
    public func stop() {
        let retired: Run? = lock.withLock {
            let old = current
            current = nil
            return old
        }
        guard let retired else { return }
        retire(retired)
        let presenter = lock.withLock { self.presenter }
        presenter.show(idleDisplay(for: retired))
        presenter.status("Playback stopped.")
    }

    /// Stops the current run unless it belongs to `recordID`.
    public func stop(unless recordID: UUID) {
        let differs: Bool = lock.withLock { current.map { $0.recordID != recordID } ?? false }
        if differs { stop() }
    }

    /// Stops playback and waits for every background release. Bounded by the
    /// native destroy timeouts; no new run can start afterwards.
    public func close() async {
        lock.withLock { closed = true }
        stop()
        let pending: [Task<Void, Never>] = lock.withLock { Array(releases.values) }
        for task in pending { await task.value }
    }

    private func idleDisplay(for run: Run) -> WindowsAudioPlaybackDisplay {
        let duration = run.handle.snapshot().duration ?? run.knownDuration
        let text = WindowsAudioPlaybackDisplay.text(position: 0, duration: duration)
        return WindowsAudioPlaybackDisplay(recordID: run.recordID, state: .idle, text: text)
    }

    /// Cancels audibly and schedules the join; never presents (the caller
    /// decides whether the display belongs to this run).
    private func retire(_ run: Run) {
        let sampler: Task<Void, Never>? = lock.withLock {
            let sampler = run.sampler
            run.sampler = nil
            return sampler
        }
        sampler?.cancel()
        run.handle.cancel()
        scheduleRelease(run)
    }

    private func scheduleRelease(_ run: Run) {
        let first: Bool = lock.withLock {
            guard !run.releaseScheduled else { return false }
            run.releaseScheduled = true
            return true
        }
        guard first else { return }
        let task = Task.detached(priority: .utility) { [weak self] in
            do {
                try run.handle.destroy()
            } catch {
                let presenter = self?.lock.withLock { self?.presenter }
                let reason = error.localizedDescription
                presenter?.status("Playback resources could not be released: \(reason)")
            }
            self?.finishRelease(run)
        }
        lock.withLock {
            // A release that already finished must not be recorded as pending.
            if !run.released { releases[run.id] = task }
        }
    }

    private func finishRelease(_ run: Run) {
        lock.withLock {
            run.released = true
            releases[run.id] = nil
            live[run.id] = nil
        }
    }

    private struct Ended {
        let run: Run
        let wasCurrent: Bool
        let presenter: WindowsAudioPlaybackPresenter
    }

    /// Runs on the native completion thread: quick, no destroy, no waiting.
    private func completed(runID: UUID, _ completion: WindowsAudioPlaybackCompletion) {
        let ended: Ended? = lock.withLock {
            guard let run = live[runID], !run.ended else { return nil }
            run.ended = true
            let wasCurrent = current === run
            if wasCurrent { current = nil }
            run.sampler?.cancel()
            run.sampler = nil
            return Ended(run: run, wasCurrent: wasCurrent, presenter: presenter)
        }
        guard let ended else { return }
        if ended.wasCurrent {
            ended.presenter.show(idleDisplay(for: ended.run))
            switch completion.status {
            case .finished: ended.presenter.status("Playback finished.")
            case .cancelled: ended.presenter.status("Playback stopped.")
            case .failed(let message): ended.presenter.status("Playback failed: \(message)")
            }
        }
        scheduleRelease(ended.run)
    }

    private func startSampler(_ run: Run) {
        let interval = self.interval
        let task = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, !Task.isCancelled else { return }
                self.sample(run)
            }
        }
        let keep: Bool = lock.withLock {
            guard current === run, !run.ended, run.sampler == nil else { return false }
            run.sampler = task
            return true
        }
        if !keep { task.cancel() }
    }

    private func sample(_ run: Run) {
        let update: (WindowsAudioPlaybackDisplay, WindowsAudioPlaybackPresenter)? = lock.withLock {
            guard current === run, !run.ended else { return nil }
            let snapshot = run.handle.snapshot()
            let state: WindowsAudioPlaybackDisplay.State
            switch snapshot.state {
            case .preparing: state = .preparing
            case .playing: state = .playing
            case .paused: state = .paused
            case .ended: return nil
            }
            let display = WindowsAudioPlaybackDisplay(
                recordID: run.recordID, state: state,
                text: WindowsAudioPlaybackDisplay.text(
                    position: snapshot.position, duration: snapshot.duration ?? run.knownDuration
                )
            )
            guard display != run.lastDisplay else { return nil }
            run.lastDisplay = display
            return (display, presenter)
        }
        if let update { update.1.show(update.0) }
    }
}
