import Foundation

/// One job's life on its serial worker: open, start, pause commands, progress
/// sampling, completion and release, plus ordered presentation delivery. None
/// of it runs on the caller's thread; all shared state is under `lock`.
extension WindowsAudioPlaybackController {
    final class Run: @unchecked Sendable {
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
        /// Stopped by the user's Stop, the only stop that reports a status.
        var stopAnnounced = false
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

    struct Presentation {
        let display: WindowsAudioPlaybackDisplay
        let status: String?
        let presenter: WindowsAudioPlaybackPresenter
    }

    func openAndStart(_ run: Run, after previous: Run?) {
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
            // A pause requested before start is honoured before any sound.
            applyPause(run)
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

    func applyPause(_ run: Run) {
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
    func release(_ run: Run) {
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
                    if let speech = speechState {
                        // Between segments the speech stays the active owner.
                        publishLocked(speech.display)
                    } else {
                        let display = WindowsAudioPlaybackDisplay(
                            recordID: run.recordID, state: .idle,
                            text: WindowsAudioPlaybackDisplay.text(position: 0, duration: run.knownDuration)
                        )
                        let status = Self.terminalMessage(run.terminal, stopAnnounced: run.stopAnnounced)
                        publishLocked(display, status: run.awaiting == nil ? status : nil)
                    }
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
                    let shown = run.outputQuiet ? speechState?.display ?? display : display
                    publishLocked(shown, status: "Playback could not close: \(error.localizedDescription)")
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
    func publishLocked(_ display: WindowsAudioPlaybackDisplay, status: String? = nil) {
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
