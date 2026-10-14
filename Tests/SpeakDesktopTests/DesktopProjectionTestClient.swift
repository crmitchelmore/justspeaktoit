import Foundation
import SpeakCore

final class DesktopProjectionTestClient: FinalizingStreamingTranscriptionClient,
    StreamingTranscriptSnapshotProviding, @unchecked Sendable {
    let finalShape = TranscriptFinalShape.standaloneSegments
    private let lock = NSLock()
    private var transcript: ((String, Bool) -> Void)?
    private var error: ((Error) -> Void)?
    private var projection = StreamingTranscriptSnapshot()
    var finalText: String?
    var finalProjection = StreamingTranscriptSnapshot()
    var onStart: (@Sendable () -> Void)?
    var onAudio: (@Sendable () -> Void)?
    var onFinish: (@Sendable () -> Void)?
    var onSnapshot: (@Sendable () -> Void)?
    var deferFinish = false
    private var finishContinuation: CheckedContinuation<String?, Never>?

    func start(onTranscript: @escaping (String, Bool) -> Void, onError: @escaping (Error) -> Void) {
        lock.withLock { transcript = onTranscript; error = onError }
        onStart?()
    }

    func sendAudio(_ audioData: Data) { onAudio?() }
    func stop() {}

    func emit(_ text: String, final: Bool = false, snapshot: StreamingTranscriptSnapshot) {
        let callback = lock.withLock { projection = snapshot; return transcript }
        callback?(text, final)
    }

    func fail() { lock.withLock { error }?(DesktopProjectionTestError()) }

    func transcriptSnapshot(captureDuration: TimeInterval) -> StreamingTranscriptSnapshot {
        onSnapshot?()
        return lock.withLock { projection }
    }

    func finishAndWait() async -> String? {
        if deferFinish {
            return await withCheckedContinuation { continuation in
                lock.withLock { finishContinuation = continuation }
                onFinish?()
            }
        }
        onFinish?()
        lock.withLock { projection = finalProjection }
        return finalText
    }

    func completeFinish() {
        let continuation = lock.withLock {
            projection = finalProjection
            let result = finishContinuation
            finishContinuation = nil
            return result
        }
        continuation?.resume(returning: finalText)
    }
}

private struct DesktopProjectionTestError: LocalizedError {
    var errorDescription: String? { "Synthetic projection failure" }
}
