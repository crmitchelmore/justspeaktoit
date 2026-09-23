import Foundation

extension WindowsAudioPlaybackController {
    /// Plays another audio source, such as synthesized speech, as the one
    /// audible output for `recordID`, replacing any current playback exactly as
    /// `play` does, and returns the seconds rendered once its output is quiet
    /// and released. Stop, a replacement, recording or close end it with
    /// `CancellationError`, as does cancelling the calling task. Pause and
    /// resume act on it like any playback of that record.
    public func playToCompletion(recordID: UUID, path: String) async throws -> TimeInterval {
        let pending = PendingRun()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let id = try admit(recordID: recordID, path: path, knownDuration: nil) {
                        continuation.resume(with: $0)
                    }
                    if pending.admitted(id) { stop(runID: id) }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if let id = pending.cancel() { stop(runID: id) }
        }
    }

    fileprivate final class PendingRun: @unchecked Sendable {
        private let lock = NSLock()
        private var id: UUID?
        private var cancelled = false

        /// Returns true when cancellation arrived before admission.
        func admitted(_ id: UUID) -> Bool { lock.withLock { self.id = id; return cancelled } }
        func cancel() -> UUID? { lock.withLock { cancelled = true; return id } }
    }

    static func outcome(_ completion: WindowsAudioPlaybackCompletion?) -> Result<TimeInterval, Error> {
        switch completion?.status {
        case .finished: return .success(completion?.played ?? 0)
        case .failed(let message): return .failure(WindowsAudioPlaybackError(message))
        case .cancelled, .none: return .failure(CancellationError())
        }
    }

    static func terminalMessage(_ completion: WindowsAudioPlaybackCompletion?) -> String {
        switch completion?.status {
        case .finished: return "Playback finished."
        case .failed(let message): return "Playback failed: \(message)"
        case .cancelled, .none: return "Playback stopped."
        }
    }
}
