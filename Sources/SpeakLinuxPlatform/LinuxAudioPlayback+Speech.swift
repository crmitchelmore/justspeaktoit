import Foundation

/// Read aloud speaks a History record as consecutive segments, each
/// synthesized before it plays. A speech keeps that record the one audible
/// owner from the click to its last segment: while a segment is synthesized
/// or between segments, the record's controls stay active (playing, or
/// paused), so Pause and Stop remain available however long synthesis takes.
extension LinuxAudioPlayback {
    /// One Read aloud of a History record, from `beginSpeech` until it ends.
    public struct Speech: Hashable, Sendable {
        public let recordID: UUID
        let id: UUID
    }

    /// A speech in progress, under `lock`.
    struct SpeechState {
        let speech: Speech
        var paused = false
    }

    /// Starts Read aloud of `recordID` before its first segment is
    /// synthesized. The current playback stops now, and the record shows
    /// speech until `endSpeech`, or until Stop, another row, recording or
    /// import, a History playback, another speech or close ends it. Play each
    /// segment with `playToCompletion(_:path:)`; segments of an ended speech
    /// are refused.
    public func beginSpeech(recordID: UUID) throws -> Speech {
        let (speech, previous) = try lock.withLock { () -> (Speech, Run?) in
            guard !closed else { throw LinuxNativeError(message: "The app is closing.") }
            let previous = current
            current = nil
            // A late terminal status of the replaced run no longer applies.
            revision &+= 1
            let state = SpeechState(speech: Speech(recordID: recordID, id: UUID()))
            speechState = state
            showLocked(state)
            return (state.speech, previous)
        }
        previous?.end(.failure(CancellationError()))
        return speech
    }

    /// Ends `speech` once its last segment has played or its reader stopped.
    /// A speech that has already ended or been replaced is left alone.
    public func endSpeech(_ speech: Speech) {
        lock.withLock {
            guard speechState?.speech == speech else { return }
            speechState = nil
            if current == nil { backend.show(speech.recordID, 0, "") }
        }
    }

    /// Plays one synthesized segment of `speech` and returns its duration once
    /// it has been heard to the end. A segment of paused speech waits, without
    /// opening the sound server, until the user resumes. A segment of a speech
    /// that has ended, for example by Stop, is refused with
    /// `CancellationError` before anything opens, and Stop, another row,
    /// History playback, recording or close end a playing one the same way,
    /// as does cancelling the calling task.
    public func playToCompletion(_ speech: Speech, path: String) async throws -> TimeInterval {
        let (samples, rate) = try Self.readPCM16WAV(URL(fileURLWithPath: path))
        try await awaitAudible(speech)
        let pending = PendingSegment()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    try admitSegment(speech, samples: samples, rate: rate, pending: pending) {
                        continuation.resume(with: $0)
                    }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if let run = pending.cancel() { stop(run) }
        }
    }

    /// Between segments, Pause and Play act on the speech itself.
    func toggleSpeechPauseLocked(recordID: UUID) -> Bool {
        guard var state = speechState, state.speech.recordID == recordID else { return false }
        state.paused.toggle()
        speechState = state
        showLocked(state)
        return true
    }

    /// Nothing is audible, so the speech acknowledges its own pause.
    func showLocked(_ state: SpeechState) {
        backend.show(state.speech.recordID, state.paused ? 2 : 1, "0:00 / --:--")
    }

    private func isActive(_ speech: Speech) -> Bool { !closed && speechState?.speech == speech }

    /// Returns once `speech` is playing rather than paused; throws
    /// `CancellationError` once it has ended or the caller is cancelled.
    private func awaitAudible(_ speech: Speech) async throws {
        while true {
            try Task.checkCancellation()
            let paused = lock.withLock { isActive(speech) ? speechState?.paused : nil }
            guard let paused else { throw CancellationError() }
            guard paused else { return }
            try await Task.sleep(nanoseconds: UInt64(backend.pollInterval * 1_000_000_000))
        }
    }

    /// The stream opens only while the speech is still active, and the run is
    /// admitted only if it still is and its caller was not cancelled meanwhile.
    private func admitSegment(
        _ speech: Speech, samples: [Int16], rate: Int, pending: PendingSegment,
        completion: @escaping (Result<TimeInterval, Error>) -> Void
    ) throws {
        guard lock.withLock({ isActive(speech) }) else { throw CancellationError() }
        let player = try backend.makePlayer(samples, rate)
        let admitted = lock.withLock { () -> (Run, Run?)? in
            guard isActive(speech) else { return nil }
            revision &+= 1
            let run = Run(
                recordID: speech.recordID, revision: revision, duration: Double(samples.count) / Double(rate),
                player: player, completion: completion
            )
            guard pending.claim(run) else { return nil }
            // A pause that arrived while the stream opened applies at once.
            if speechState?.paused == true { _ = run.with { $0.setPaused(true) } }
            return (run, replaceLocked(with: run))
        }
        guard let (run, previous) = admitted else {
            player.destroy()
            throw CancellationError()
        }
        previous?.end(.failure(CancellationError()))
        watch(run)
    }

    /// Ends `run` if it is still current; the speech it belongs to, if still
    /// active, stays shown.
    private func stop(_ run: Run) {
        let ended = lock.withLock { () -> Bool in
            guard current === run else { return false }
            current = nil
            if let speech = speechState, speech.speech.recordID == run.recordID {
                showLocked(speech)
            } else {
                backend.show(run.recordID, 0, "")
            }
            return true
        }
        if ended { run.end(.failure(CancellationError())) }
    }
}

/// Cancellation and admission meet under this lock, taken inside the
/// playback's: either the caller was cancelled first and nothing is admitted,
/// or the run is claimed first and cancellation stops it.
private final class PendingSegment: @unchecked Sendable {
    private let lock = NSLock()
    private var run: LinuxAudioPlayback.Run?
    private var cancelled = false

    func claim(_ run: LinuxAudioPlayback.Run) -> Bool {
        lock.withLock {
            guard !cancelled else { return false }
            self.run = run
            return true
        }
    }

    func cancel() -> LinuxAudioPlayback.Run? { lock.withLock { cancelled = true; return run } }
}
