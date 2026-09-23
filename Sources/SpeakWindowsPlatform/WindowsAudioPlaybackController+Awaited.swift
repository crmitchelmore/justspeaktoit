import Foundation

extension WindowsAudioPlaybackController {
    /// Plays another audio source, such as synthesized speech, as the one
    /// audible output for `recordID`, replacing any current playback exactly as
    /// `play` does, and returns the seconds rendered once its output is quiet
    /// and released. Stop, a replacement, recording or close end it with
    /// `CancellationError`, as does cancelling the calling task. A caller
    /// cancelled before admission replaces nothing and opens no file, so a
    /// superseded request can never stop the playback that superseded it.
    /// Pause and resume act on it like any playback of that record.
    public func playToCompletion(recordID: UUID, path: String) async throws -> TimeInterval {
        let pending = PendingRun()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    _ = try admit(recordID: recordID, path: path, knownDuration: nil, awaiting: {
                        continuation.resume(with: $0)
                    }, claim: pending.claim)
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if let id = pending.cancel() { stop(runID: id) }
        }
    }

    /// Cancellation and admission meet under this lock, taken inside the
    /// controller's: either the caller was cancelled first and nothing is
    /// admitted, or the run is claimed first and cancellation stops it.
    fileprivate final class PendingRun: @unchecked Sendable {
        private let lock = NSLock()
        private var id: UUID?
        private var cancelled = false

        func claim(_ id: UUID) -> Bool {
            lock.withLock {
                guard !cancelled else { return false }
                self.id = id
                return true
            }
        }

        func cancel() -> UUID? { lock.withLock { cancelled = true; return id } }
    }

    static func outcome(_ completion: WindowsAudioPlaybackCompletion?) -> Result<TimeInterval, Error> {
        switch completion?.status {
        case .finished: return .success(completion?.played ?? 0)
        case .failed(let message): return .failure(WindowsAudioPlaybackError(message))
        case .cancelled, .none: return .failure(CancellationError())
        }
    }

    /// A finished or failed run always reports; a stopped one only when the
    /// user's Stop ended it.
    static func terminalMessage(_ completion: WindowsAudioPlaybackCompletion?, stopAnnounced: Bool) -> String? {
        switch completion?.status {
        case .finished: return "Playback finished."
        case .failed(let message): return "Playback failed: \(message)"
        case .cancelled, .none: return stopAnnounced ? "Playback stopped." : nil
        }
    }
}
